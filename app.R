# ============================================
# What's Going Downham - Downham Market Events Website
# A Shiny app for submitting and viewing local events
# ============================================

# ---- Packages ----
# If any of these aren't installed yet, run (once):
# install.packages(c("shiny", "DT", "DBI", "RSQLite", "dplyr", "lubridate", "bslib"))
library(shiny)
library(DT)
library(DBI)
library(RSQLite)
library(dplyr)
library(lubridate)
library(bslib)

# ---- Database setup ----
# Using SQLite so submissions persist between app restarts.
# The database file (events.db) is created automatically in the
# same folder as this app the first time it runs.

db_path <- "events.db"

init_db <- function() {
  con <- dbConnect(RSQLite::SQLite(), db_path)
  if (!dbExistsTable(con, "events")) {
    dbExecute(con, "
      CREATE TABLE events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        description TEXT,
        location TEXT,
        event_date TEXT NOT NULL,
        start_time TEXT,
        end_time TEXT,
        url TEXT,
        is_recurring INTEGER NOT NULL DEFAULT 0,
        recurrence_rule TEXT,
        series_id TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        submitted_at TEXT NOT NULL
      )
    ")
  } else {
    # Migrate a database created by an earlier version of this app,
    # which won't have these columns yet.
    existing_cols <- dbListFields(con, "events")
    if (!"start_time" %in% existing_cols) dbExecute(con, "ALTER TABLE events ADD COLUMN start_time TEXT")
    if (!"end_time" %in% existing_cols) dbExecute(con, "ALTER TABLE events ADD COLUMN end_time TEXT")
    if (!"url" %in% existing_cols) dbExecute(con, "ALTER TABLE events ADD COLUMN url TEXT")
    if (!"series_id" %in% existing_cols) dbExecute(con, "ALTER TABLE events ADD COLUMN series_id TEXT")
  }
  dbDisconnect(con)
}

init_db()

# Helper: open a fresh connection whenever we need one.
# (Simpler and safer for a small app than keeping one connection open
# for the whole session.)
get_con <- function() {
  dbConnect(RSQLite::SQLite(), db_path)
}

# ---- Admin password ----
# CHANGE THIS before you share the app publicly. This is a very basic
# gate suitable for a low-stakes community site, not real security.
ADMIN_PASSWORD <- Sys.getenv("SHINY_APP_PASSWORD")

# ---- Site branding ----
# Change these to personalise the site.
SITE_TITLE <- "What's Going Downham"
VILLAGE_NAME <- "Downham Market"

# Colour palette, reused across the theme, the table highlighting and
# the calendar. Change these two hex codes to re-colour the whole site.
COLOR_PRIMARY <- "#3f6d4e"    # one-off events, buttons, links
COLOR_ACCENT <- "#caa156"     # recurring events
COLOR_ACCENT_TINT <- "#f5ead2"  # pale version of the accent, for row/date highlighting

# ---- Helper functions ----

# Builds a dropdown of times in fixed intervals, e.g. "5:00 AM", "5:30 AM", ...
# The dropdown VALUE stored/returned is 24-hour "HH:MM" (so it sorts correctly
# as plain text); the LABEL shown to the user is a friendly 12-hour version.
generate_time_choices <- function(interval_minutes = 30) {
  total_slots <- (24 * 60) / interval_minutes
  times_24h <- vapply(0:(total_slots - 1), function(i) {
    total_minutes <- i * interval_minutes
    sprintf("%02d:%02d", total_minutes %/% 60, total_minutes %% 60)
  }, character(1))

  hour <- as.integer(substr(times_24h, 1, 2))
  minute <- substr(times_24h, 4, 5)
  period <- ifelse(hour < 12, "AM", "PM")
  hour12 <- hour %% 12
  hour12[hour12 == 0] <- 12
  labels <- paste0(hour12, ":", minute, " ", period)

  setNames(times_24h, labels)
}

time_choices <- generate_time_choices()

# Converts a stored 24-hour time ("17:00") into a compact 12-hour label
# ("5pm", or "5:30pm" when the minutes aren't zero). Vectorised, and
# returns NA for blank/missing input.
format_time_12h_vec <- function(time_24h) {
  hour <- suppressWarnings(as.integer(substr(time_24h, 1, 2)))
  minute <- substr(time_24h, 4, 5)
  period <- ifelse(hour < 12, "am", "pm")
  hour12 <- hour %% 12
  hour12[hour12 == 0] <- 12
  label <- ifelse(minute == "00", paste0(hour12, period), paste0(hour12, ":", minute, period))
  ifelse(is.na(time_24h) | time_24h == "", NA_character_, label)
}

# Combines a start/end time pair into one display string for the table,
# e.g. "5pm" (start only) or "5pm-6pm" (both).
format_time_range_vec <- function(start_time, end_time) {
  start_label <- format_time_12h_vec(start_time)
  end_label <- format_time_12h_vec(end_time)
  dplyr::case_when(
    !is.na(start_label) & !is.na(end_label) ~ paste0(start_label, "-", end_label),
    !is.na(start_label) ~ start_label,
    !is.na(end_label) ~ end_label,
    TRUE ~ ""
  )
}

# Turns a day number into "1st"/"2nd"/"3rd"/"4th"... (correct suffix).
ordinal_label_vec <- function(day) {
  last_digit <- day %% 10
  ifelse(day %in% 11:13, paste0(day, "th"),
    ifelse(last_digit == 1, paste0(day, "st"),
    ifelse(last_digit == 2, paste0(day, "nd"),
    ifelse(last_digit == 3, paste0(day, "rd"), paste0(day, "th")))))
}

# Turns a Date into "1st Aug 2026".
format_date_ordinal_vec <- function(date) {
  day <- as.integer(format(date, "%d"))
  paste0(ordinal_label_vec(day), " ", format(date, "%b %Y"))
}

# Combines date and time into one string for the table, e.g.
# "1st Aug 2026, 2:30pm-8:00pm", or just the date when no time was given.
format_when_vec <- function(date, start_time, end_time) {
  date_label <- format_date_ordinal_vec(date)
  time_label <- format_time_range_vec(start_time, end_time)
  ifelse(nzchar(time_label), paste0(date_label, ", ", time_label), date_label)
}

# ---- Recurrence helpers ----
# These generate the individual occurrence dates for a recurring event
# from a simple pattern (weekly / fortnightly / same date each month /
# "nth weekday of the month", e.g. "2nd Sunday"), so the person
# submitting only has to describe the pattern once rather than typing
# out every date.

days_in_month_ymd <- function(year, month) {
  next_month_first <- if (month == 12) {
    as.Date(sprintf("%04d-01-01", year + 1))
  } else {
    as.Date(sprintf("%04d-%02d-01", year, month + 1))
  }
  as.integer(format(next_month_first - 1, "%d"))
}

# The nth occurrence of a given ISO weekday (1 = Monday ... 7 = Sunday)
# in a given month, or NA if that month doesn't have an nth one.
nth_weekday_date <- function(year, month, iso_weekday, n) {
  first_of_month <- as.Date(sprintf("%04d-%02d-01", year, month))
  first_wday <- as.integer(format(first_of_month, "%u"))
  offset <- (iso_weekday - first_wday) %% 7
  candidate <- first_of_month + offset + (n - 1) * 7
  if (as.integer(format(candidate, "%m")) == month) candidate else NA
}

# The LAST occurrence of a given weekday in a month (handles months
# that have four vs. five of a given weekday).
last_weekday_of_month <- function(year, month, iso_weekday) {
  five <- nth_weekday_date(year, month, iso_weekday, 5)
  if (!is.na(five)) return(five)
  nth_weekday_date(year, month, iso_weekday, 4)
}

# Same day-of-month every month, clamped to the last day of a
# shorter month (e.g. the 31st in February becomes the 28th/29th).
generate_monthly_same_date <- function(start_date, count) {
  day_num <- as.integer(format(start_date, "%d"))
  y <- as.integer(format(start_date, "%Y"))
  m <- as.integer(format(start_date, "%m"))
  dates <- vector("list", count)
  for (i in seq_len(count)) {
    tm <- m + (i - 1)
    ty <- y + (tm - 1) %/% 12
    tm <- ((tm - 1) %% 12) + 1
    dates[[i]] <- as.Date(sprintf("%04d-%02d-%02d", ty, tm, min(day_num, days_in_month_ymd(ty, tm))))
  }
  as.Date(unlist(dates), origin = "1970-01-01")
}

# The same weekday-position each month (e.g. every 2nd Sunday, or
# every LAST Friday) - the position is worked out from the start date
# itself, so there's nothing extra to select.
generate_monthly_nth_weekday <- function(start_date, count) {
  iso_weekday <- as.integer(format(start_date, "%u"))
  day_of_month <- as.integer(format(start_date, "%d"))
  dim_start <- days_in_month_ymd(as.integer(format(start_date, "%Y")), as.integer(format(start_date, "%m")))
  n <- ceiling(day_of_month / 7)
  is_last <- (day_of_month + 7) > dim_start
  y <- as.integer(format(start_date, "%Y"))
  m <- as.integer(format(start_date, "%m"))
  dates <- vector("list", count)
  for (i in seq_len(count)) {
    tm <- m + (i - 1)
    ty <- y + (tm - 1) %/% 12
    tm <- ((tm - 1) %% 12) + 1
    dates[[i]] <- if (is_last) last_weekday_of_month(ty, tm, iso_weekday) else nth_weekday_date(ty, tm, iso_weekday, n)
  }
  as.Date(unlist(dates), origin = "1970-01-01")
}

# Generates up to 12 occurrence dates for the chosen pattern.
generate_occurrence_dates <- function(recur_type, start_date, count) {
  count <- max(1, min(12, as.integer(count)))
  switch(recur_type,
    weekly = start_date + (0:(count - 1)) * 7,
    fortnightly = start_date + (0:(count - 1)) * 14,
    monthly_date = generate_monthly_same_date(start_date, count),
    monthly_nth_weekday = generate_monthly_nth_weekday(start_date, count),
    start_date
  )
}

# A human-readable description of the pattern, stored as recurrence_rule
# and shown in the table/calendar (e.g. "Every 2nd Sunday of the month").
describe_recurrence <- function(recur_type, start_date, custom_text) {
  weekday_name <- format(start_date, "%A")
  day_of_month <- as.integer(format(start_date, "%d"))
  dim_start <- days_in_month_ymd(as.integer(format(start_date, "%Y")), as.integer(format(start_date, "%m")))
  n <- ceiling(day_of_month / 7)
  is_last <- (day_of_month + 7) > dim_start
  nth_label <- if (is_last) "last" else ordinal_label_vec(n)

  switch(recur_type,
    weekly = paste("Every", weekday_name),
    fortnightly = paste0("Every 2 weeks (", weekday_name, ")"),
    monthly_date = paste0("Monthly on the ", ordinal_label_vec(day_of_month)),
    monthly_nth_weekday = paste0("Every ", nth_label, " ", weekday_name, " of the month"),
    custom_text
  )
}

# A short random ID shared by every occurrence generated from one
# submission, so the Admin tab can group and act on them together.
generate_series_id <- function() {
  paste0(as.integer(Sys.time()), "-", sample(100000:999999, 1))
}

# Tags each row with the series it belongs to - its own series_id if
# it's part of a recurring group, otherwise a key unique to that row
# (so a plain one-off event forms a "group" of one).
add_group_key <- function(df) {
  df %>% mutate(group_key = ifelse(is.na(series_id) | series_id == "", paste0("single-", id), series_id))
}

# Escapes text for safe use inside an HTML attribute (e.g. an href) -
# stops a submitted URL from being able to break out of the attribute
# and inject extra HTML, regardless of what the link points to.
escape_attr <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x
}

# Builds a clickable link for any non-blank URL. All submitted events
# are reviewed by an admin before they go public, so every link is
# shown as a hyperlink rather than only ones starting with http(s).
make_link_cell <- function(url) {
  ifelse(!is.na(url) & nzchar(url),
         paste0('<a href="', escape_attr(url), '" target="_blank">Link</a>'),
         "")
}

# ============================================
# UI
# ============================================

ui <- fluidPage(
  theme = bs_theme(
    version = 5,
    bg = "#8EC28D",
    fg = "#2b2b2b",
    primary = COLOR_PRIMARY,
    secondary = COLOR_ACCENT,
    base_font = font_google("Inter"),
    heading_font = font_google("Fraunces")
  ),
  tags$head(
    tags$script(src = "https://cdn.jsdelivr.net/npm/fullcalendar@6.1.11/index.global.min.js"),
    tags$style(HTML(paste0("
      body { padding-bottom: 40px; }
      .container-fluid { max-width: 1100px; }
      h2, h4 { letter-spacing: 0.02em; }
      #whats_on_calendar {
        --fc-button-bg-color: ", COLOR_PRIMARY, ";
        --fc-button-border-color: ", COLOR_PRIMARY, ";
        --fc-button-hover-bg-color: ", COLOR_PRIMARY, ";
        --fc-button-active-bg-color: ", COLOR_PRIMARY, ";
        --fc-today-bg-color: ", COLOR_ACCENT_TINT, ";
        --fc-border-color: #e2ded6;
      }
      /* Let event titles wrap instead of being clipped, and let each
         day's cell grow to fit its events instead of hiding any. */
      #whats_on_calendar .fc-daygrid-event-harness .fc-event-title {
        white-space: normal;
        overflow: visible;
        text-overflow: unset;
        line-height: 1.25;
      }
      #whats_on_calendar .fc-daygrid-day-frame {
        min-height: 90px;
      }
    ")))
  ),
  titlePanel(SITE_TITLE),

  tabsetPanel(
    id = "main_tabs",

    # ---- TAB 1: Public "What's On" listing ----
    tabPanel(
      "What's On",
      br(),
      p(paste0("A guide to upcoming events in Downham Market. See what events are on, and add your own. No adverts, no spam.")),
      checkboxInput("show_recurring", "Include recurring events/classes.", value = FALSE),
      DTOutput("public_events_table"),
      hr(),
      h4("Calendar view"),
      p("Click an event in the calendar for full details."),
      tags$div(id = "whats_on_calendar", style = "max-width: 900px; margin-bottom: 40px;"),
      tags$script(HTML("
        $(document).ready(function() {
          var calendarEl = document.getElementById('whats_on_calendar');
          var calendar = new FullCalendar.Calendar(calendarEl, {
            initialView: 'dayGridMonth',
            height: 650,
            displayEventTime: false,
            dayMaxEventRows: false,
            events: [],
            eventClick: function(info) {
              info.jsEvent.preventDefault();
              Shiny.setInputValue('calendar_event_click', {
                title: info.event.title,
                date: info.event.extendedProps.date_label,
                location: info.event.extendedProps.location,
                description: info.event.extendedProps.description,
                recurrence: info.event.extendedProps.recurrence_rule,
                start_time_label: info.event.extendedProps.start_time_label,
                end_time_label: info.event.extendedProps.end_time_label,
                url: info.event.extendedProps.url
              }, {priority: 'event'});
            }
          });
          calendar.render();

          Shiny.addCustomMessageHandler('updateCalendarEvents', function(events) {
            calendar.removeAllEvents();
            events.forEach(function(e) { calendar.addEvent(e); });
          });
        });
      "))
    ),

    # ---- TAB 2: Submission form ----
    tabPanel(
      "Submit an Event",
      br(),
      fluidRow(
        column(
          width = 6,
          textInput("sub_title", "Event title", placeholder = "e.g. Summer Fete"),
          textAreaInput("sub_description", "Description", rows = 4,
                        placeholder = "A few sentences about the event"),
          textInput("sub_location", "Location", placeholder = "e.g. Town Hall"),
          dateInput("sub_date", "Date", value = Sys.Date()),
          selectInput("sub_start_time", "Start time (optional)",
                      choices = c("(No specific time)" = "", time_choices)),
          selectInput("sub_end_time", "End time (optional)",
                      choices = c("(No specific time)" = "", time_choices)),
          textInput("sub_url", "Event URL (optional)",
                    placeholder = "https://example.com/event-details"),
          checkboxInput("sub_recurring", "This is a recurring event/class", value = FALSE),
          conditionalPanel(
            condition = "input.sub_recurring == true",
            selectInput("sub_recurrence_type", "Repeats",
                        choices = c("Weekly" = "weekly",
                                    "Fortnightly" = "fortnightly",
                                    "Monthly (same date each month)" = "monthly_date",
                                    "Monthly (e.g. 2nd Sunday)" = "monthly_nth_weekday",
                                    "Other / describe it" = "custom")),
            conditionalPanel(
              condition = "input.sub_recurrence_type != 'custom'",
              numericInput("sub_recurrence_count", "Number of occurrences (max 12)",
                           value = 4, min = 1, max = 12),
              helpText("The pattern follows the Date above - e.g. if that's a 2nd Sunday, ",
                       "\"Monthly (e.g. 2nd Sunday)\" repeats on the 2nd Sunday of each month.")
            ),
            conditionalPanel(
              condition = "input.sub_recurrence_type == 'custom'",
              textInput("sub_recurrence_text", "Describe how it repeats",
                        placeholder = "e.g. Every 2nd and 4th Tuesday")
            )
          ),
          actionButton("submit_btn", "Submit event", class = "btn-primary"),
          br(), br(),
          textOutput("submit_confirmation")
        )
      )
    ),

    # ---- TAB 3: Admin approval ----
    tabPanel(
      "Admin",
      br(),
      uiOutput("admin_ui")
    )
  )
)

# ============================================
# SERVER
# ============================================

server <- function(input, output, session) {

  # A "refresh trigger" - bumping this forces tables to reload from the DB
  refresh_trigger <- reactiveVal(0)

  # ---- Read all events from the database ----
  all_events <- reactive({
    refresh_trigger()  # take a dependency, so this reruns after any change
    con <- get_con()
    on.exit(dbDisconnect(con))
    dbReadTable(con, "events")
  })

  # ---- Public "What's On" table ----
  output$public_events_table <- renderDT({
    events <- all_events() %>%
      filter(status == "approved")

    if (!isTRUE(input$show_recurring)) {
      events <- events %>% filter(is_recurring == 0)
    }

    events <- events %>%
      mutate(
        event_date = as.Date(event_date),
        `Recurring?` = ifelse(is_recurring == 1, recurrence_rule, "No"),
        When = format_when_vec(event_date, start_time, end_time),
        Link = make_link_cell(url)
      ) %>%
      arrange(event_date, desc(is.na(start_time)), start_time) %>%
      select(Event = title, When, Location = location, Description = description,
             Link, `Recurring?`, is_recurring)

    datatable(
      events,
      rownames = FALSE,
      style = "bootstrap5",
      escape = -which(names(events) == "Link"),
      options = list(
        pageLength = 15,
        # The rows are already sorted chronologically above; sorting by
        # the displayed "When" text wouldn't sort correctly (e.g. "1st"
        # before "10th"), so no column-based sort is applied here.
        order = list(),
        columnDefs = list(
          list(orderable = FALSE, targets = 1),
          # is_recurring is only kept to drive the row highlighting below,
          # not for display, since "Recurring?" now shows text that varies.
          list(visible = FALSE, targets = which(names(events) == "is_recurring") - 1)
        )
      )
    ) %>%
      formatStyle(
        "is_recurring",
        target = "row",
        backgroundColor = styleEqual(1, COLOR_ACCENT_TINT)
      )
  })

  # ---- Keep the calendar view in sync with approved events ----
  observe({
    events <- all_events() %>%
      filter(status == "approved")

    if (!isTRUE(input$show_recurring)) {
      events <- events %>% filter(is_recurring == 0)
    }

    events <- events %>%
      mutate(event_date = as.character(as.Date(event_date))) %>%
      arrange(as.Date(event_date), desc(is.na(start_time)), start_time)

    calendar_events <- lapply(seq_len(nrow(events)), function(i) {
      row <- events[i, ]

      has_start_time <- !is.na(row$start_time) && nzchar(row$start_time)
      has_end_time <- !is.na(row$end_time) && nzchar(row$end_time)
      start_label <- format_time_12h_vec(row$start_time)
      end_label <- format_time_12h_vec(row$end_time)

      # Prepend the start time to the title (e.g. "5pm: Example Event").
      # Recurring events are shown in a different colour rather than
      # extra text, to leave more room for the title itself.
      title_text <- row$title
      if (!is.na(start_label)) title_text <- paste0(start_label, ": ", title_text)

      # A real datetime (not just a date) lets the calendar sort same-day
      # events by actual start time, rather than alphabetically by title.
      event_obj <- list(
        title = title_text,
        start = if (has_start_time) paste0(row$event_date, "T", row$start_time, ":00") else row$event_date,
        allDay = !has_start_time,
        color = if (isTRUE(row$is_recurring == 1)) COLOR_ACCENT else COLOR_PRIMARY,
        extendedProps = list(
          location = row$location,
          description = row$description,
          recurrence_rule = row$recurrence_rule,
          date_label = format(as.Date(row$event_date), "%d %b %Y"),
          start_time_label = start_label,
          end_time_label = end_label,
          url = row$url
        )
      )
      if (has_end_time) {
        event_obj$end <- paste0(row$event_date, "T", row$end_time, ":00")
      }
      event_obj
    })

    session$sendCustomMessage("updateCalendarEvents", calendar_events)
  })

  # ---- Show event details when a calendar event is clicked ----
  observeEvent(input$calendar_event_click, {
    info <- input$calendar_event_click
    time_text <- info$start_time_label
    if (!is.null(info$end_time_label) && nzchar(info$end_time_label)) {
      time_text <- paste0(time_text, " \u2013 ", info$end_time_label)
    }

    showModal(modalDialog(
      title = info$title,
      tags$p(tags$strong("Date: "), info$date),
      if (!is.null(time_text) && nzchar(time_text)) tags$p(tags$strong("Time: "), time_text),
      if (!is.null(info$location) && nzchar(info$location)) tags$p(tags$strong("Location: "), info$location),
      if (!is.null(info$recurrence) && nzchar(info$recurrence)) tags$p(tags$strong("Recurs: "), info$recurrence),
      if (!is.null(info$description) && nzchar(info$description)) tags$p(info$description),
      if (!is.null(info$url) && nzchar(info$url)) {
        tags$p(tags$a(href = info$url, target = "_blank", "More info"))
      },
      easyClose = TRUE,
      footer = modalButton("Close")
    ))
  })

  # ---- Handle new submissions ----
  observeEvent(input$submit_btn, {
    req(input$sub_title, input$sub_date)

    start_time_val <- if (nzchar(input$sub_start_time)) input$sub_start_time else NA
    end_time_val <- if (nzchar(input$sub_end_time)) input$sub_end_time else NA
    url_val <- if (nzchar(input$sub_url)) input$sub_url else NA

    con <- get_con()

    insert_one <- function(event_date, series_id, recurrence_rule) {
      dbExecute(con, "
        INSERT INTO events (title, description, location, event_date, start_time, end_time, url,
                             is_recurring, recurrence_rule, series_id, status, submitted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
      ", params = list(
        input$sub_title,
        input$sub_description,
        input$sub_location,
        as.character(event_date),
        start_time_val,
        end_time_val,
        url_val,
        as.integer(input$sub_recurring),
        recurrence_rule,
        series_id,
        as.character(Sys.time())
      ))
    }

    if (input$sub_recurring && input$sub_recurrence_type != "custom") {
      # A structured pattern (weekly/fortnightly/monthly): generate every
      # occurrence now and insert them as one series, capped at 12 rows.
      occurrence_dates <- generate_occurrence_dates(
        input$sub_recurrence_type, input$sub_date, input$sub_recurrence_count
      )
      series_id <- generate_series_id()
      rule_label <- describe_recurrence(input$sub_recurrence_type, input$sub_date, NA)
      for (d in occurrence_dates) {
        insert_one(as.Date(d, origin = "1970-01-01"), series_id, rule_label)
      }
    } else {
      # A one-off event, or a recurring pattern too irregular to describe
      # with the dropdown - stored as a single row, shown once.
      rule_label <- if (input$sub_recurring) {
        describe_recurrence("custom", input$sub_date, input$sub_recurrence_text)
      } else {
        NA
      }
      insert_one(input$sub_date, NA, rule_label)
    }

    dbDisconnect(con)

    # Clear the form so it's ready for the next submission
    updateTextInput(session, "sub_title", value = "")
    updateTextAreaInput(session, "sub_description", value = "")
    updateTextInput(session, "sub_location", value = "")
    updateDateInput(session, "sub_date", value = Sys.Date())
    updateSelectInput(session, "sub_start_time", selected = "")
    updateSelectInput(session, "sub_end_time", selected = "")
    updateTextInput(session, "sub_url", value = "")
    updateCheckboxInput(session, "sub_recurring", value = FALSE)
    updateSelectInput(session, "sub_recurrence_type", selected = "weekly")
    updateNumericInput(session, "sub_recurrence_count", value = 4)
    updateTextInput(session, "sub_recurrence_text", value = "")

    output$submit_confirmation <- renderText({
      "Thanks! Your event has been submitted and will appear once approved."
    })

    refresh_trigger(refresh_trigger() + 1)
  })

  # ---- Admin: simple login gate ----
  admin_logged_in <- reactiveVal(FALSE)

  output$admin_ui <- renderUI({
    if (!admin_logged_in()) {
      tagList(
        passwordInput("admin_password", "Admin password"),
        actionButton("admin_login_btn", "Log in")
      )
    } else {
      tagList(
        h4("Pending events"),
        p("Select the rows you want to act on, then click a button below. A recurring event's occurrences are grouped into one row, so approving or rejecting it applies to the whole series."),
        DTOutput("pending_events_table"),
        actionButton("approve_btn", "Approve selected", class = "btn-success"),
        actionButton("reject_btn", "Reject selected", class = "btn-danger")
      )
    }
  })

  observeEvent(input$admin_login_btn, {
    if (identical(input$admin_password, Sys.getenv("SHINY_APP_PASSWORD"))) {
      admin_logged_in(TRUE)
    } else {
      showNotification("Incorrect password", type = "error")
    }
  })

  # A recurring submission creates several rows sharing one series_id;
  # this groups them into a single row for review, so approving/rejecting
  # a 12-week class is one click instead of twelve.
  pending_grouped <- reactive({
    all_events() %>%
      filter(status == "pending") %>%
      add_group_key() %>%
      group_by(group_key) %>%
      summarise(
        title = first(title),
        first_date = min(as.Date(event_date)),
        occurrences = n(),
        start_time = first(start_time),
        end_time = first(end_time),
        url = first(url),
        location = first(location),
        is_recurring = first(is_recurring),
        recurrence_rule = first(recurrence_rule),
        description = first(description),
        .groups = "drop"
      ) %>%
      arrange(first_date)
  })

  output$pending_events_table <- renderDT({
    events <- pending_grouped() %>%
      mutate(
        `First date` = format(first_date, "%d %b %Y"),
        Time = format_time_range_vec(start_time, end_time),
        Link = make_link_cell(url),
        `Recurring?` = ifelse(is_recurring == 1, recurrence_rule, "No")
      ) %>%
      select(Title = title, `First date`, Occurrences = occurrences, Time,
             Location = location, Link, `Recurring?`, Description = description)

    datatable(events, rownames = FALSE, selection = "multiple",
              style = "bootstrap5",
              escape = -which(names(events) == "Link"),
              options = list(pageLength = 10))
  })

  observeEvent(input$approve_btn, {
    req(input$pending_events_table_rows_selected)
    selected_keys <- pending_grouped()$group_key[input$pending_events_table_rows_selected]
    pending <- all_events() %>% filter(status == "pending") %>% add_group_key()
    ids_to_approve <- pending$id[pending$group_key %in% selected_keys]

    con <- get_con()
    for (event_id in ids_to_approve) {
      dbExecute(con, "UPDATE events SET status = 'approved' WHERE id = ?",
                params = list(event_id))
    }
    dbDisconnect(con)
    refresh_trigger(refresh_trigger() + 1)
  })

  observeEvent(input$reject_btn, {
    req(input$pending_events_table_rows_selected)
    selected_keys <- pending_grouped()$group_key[input$pending_events_table_rows_selected]
    pending <- all_events() %>% filter(status == "pending") %>% add_group_key()
    ids_to_reject <- pending$id[pending$group_key %in% selected_keys]

    con <- get_con()
    for (event_id in ids_to_reject) {
      dbExecute(con, "UPDATE events SET status = 'rejected' WHERE id = ?",
                params = list(event_id))
    }
    dbDisconnect(con)
    refresh_trigger(refresh_trigger() + 1)
  })
}

shinyApp(ui, server)
