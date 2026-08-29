# What's Going Downham — Shiny App

## What this is

A single-file Shiny app (`app.R`) with three tabs:

- **What's On** — public list of approved events, sorted chronologically,
  with recurring events highlighted, plus a month calendar view
  underneath showing the start time on each event (e.g. "5pm: Example
  Event") and recurring events shown in a different colour. A "Show
  recurring events/classes" checkbox (off by default) controls both
  the table and the calendar at once. Click any event in the calendar
  to see its full details (time, location, description, recurrence,
  and a link if one was given).
- **Submit an Event** — anyone can add an event, with an optional
  start time, end time, and a URL for more details. Recurring events
  use a pattern (Weekly / Fortnightly / Monthly on the same date /
  Monthly on the same weekday-position, e.g. "2nd Sunday" / Other) and
  a capped number of occurrences (max 12), rather than typing out
  every date. New submissions start as "pending" and don't appear
  publicly until approved.
- **Admin** — password-gated tab where you approve or reject pending
  submissions. A recurring submission's occurrences are grouped into
  one row here, so approving or rejecting it applies to the whole
  series in one click. Start time, end time and a clickable link are
  shown too, so you can check everything before approving.

Data is stored in a local SQLite file (`events.db`), created
automatically the first time the app runs, so submissions survive
between restarts.

## Running it locally

1. Install R and RStudio if you don't already have them.
2. Open `app.R` in RStudio.
3. Install the required packages (only needed once):

   ```r
   install.packages(c("shiny", "DT", "DBI", "RSQLite", "dplyr", "lubridate", "bslib"))
   ```

4. Click "Run App" in RStudio (or run `shiny::runApp()` in the console).

## Before you show it to anyone else

Open `app.R` and change this line near the top:

```r
ADMIN_PASSWORD <- "changeme123"
```

to a password only you know. This is a simple gate suitable for a
small community site — it's not bank-grade security, but it stops
casual snooping.

## Putting it online (free)

1. Create a free account at [shinyapps.io](https://www.shinyapps.io/).
2. In RStudio, install `rsconnect`:

   ```r
   install.packages("rsconnect")
   ```

3. Follow the "Tokens" page on shinyapps.io to connect your account
   (it gives you a short snippet to paste into the R console — you
   only do this once).
4. With `app.R` open, click the "Publish" button in RStudio (top-right
   of the editor pane), or run:

   ```r
   rsconnect::deployApp()
   ```

5. You'll get a public URL like `https://yourname.shinyapps.io/whats-going-downham`
   that you can share with Downham Market.

The free tier has a monthly usage limit (active hours), which is
normally plenty for a town-sized audience.

## A custom domain (e.g. on Posit Connect Cloud)

If you're hosting on [Posit Connect Cloud](https://connect.posit.cloud)
rather than shinyapps.io, custom domains are supported, but only on
the paid **Enhanced** tier and above (not the free tier). Roughly:

1. Buy a domain if you don't already have one (via any registrar -
   e.g. Namecheap, GoDaddy, IONOS).
2. In Connect Cloud, go to **Admin → Domains → + Add Domain** and
   enter it.
3. Connect Cloud gives you DNS records (typically a CNAME) to add at
   your domain registrar. This is usually done from your registrar's
   "DNS settings" page, not from Connect Cloud itself.
4. Back in Connect Cloud, click **Verify** - this can take anywhere
   from a few minutes up to 72 hours while the DNS change spreads
   across the internet.
5. Once verified, assign the domain to this app from its content
   settings.

SSL/HTTPS (the padlock icon) is handled automatically once the domain
is verified - nothing extra to configure there.

If you'd rather not pay for a custom domain yet, Connect Cloud also
lets you customise the free `connect.posit.cloud/...` URL slug itself,
which is a free way to make the address a bit more presentable in the
meantime.

## Personalising the site

Near the top of `app.R` there's a branding section:

```r
SITE_TITLE <- "What's Going Downham"
VILLAGE_NAME <- "Downham Market"

COLOR_PRIMARY <- "#3f6d4e"
COLOR_ACCENT <- "#caa156"
COLOR_ACCENT_TINT <- "#f5ead2"
```

Change `SITE_TITLE` and `VILLAGE_NAME` to update the page title and
the intro text. The three colours flow through the whole site — the
overall theme, the "Recurring" highlighting in the table, and the
calendar's event colours — so changing them re-colours everything
consistently in one place.

The look is built with [bslib](https://rstudio.github.io/bslib/),
using the Fraunces (headings) and Inter (body text) fonts from Google
Fonts, loaded via a CDN alongside FullCalendar — so, as with the
calendar, an internet connection is needed for the fonts and calendar
to display correctly (the rest of the app works fine offline, just
with a plainer look and default fonts).

## About recurring events

Instead of typing a recurrence rule as free text, the submitter picks
a pattern:

- **Weekly** / **Fortnightly** — same weekday as the Date they picked.
- **Monthly (same date each month)** — e.g. the 15th of every month;
  clamped to the last day of shorter months (the 31st in February
  becomes the 28th/29th).
- **Monthly (e.g. 2nd Sunday)** — the same weekday-position each
  month, worked out from the Date they picked (so picking a 2nd
  Sunday repeats on the 2nd Sunday of each following month; a "5th"
  occurrence that some months don't have is simply skipped that
  month, rather than landing on the wrong week).
- **Other / describe it** — free text, for anything too irregular for
  the patterns above (e.g. "2nd and 4th Tuesday"). This one is stored
  and shown once rather than expanded into individual dates.

For the four structured patterns, the app generates every date up
front (capped at 12) and inserts them as real, individual events -
each shows up on its own date in the table and calendar, rather than
as one vague listing. All the occurrences from one submission share
an internal "series" ID, which is what lets the Admin tab group and
approve/reject them as a single row instead of up to twelve.

If you'd like a higher or lower cap than 12, search `app.R` for
`max = 12` (in the submission form) and `min(12,` (in
`generate_occurrence_dates`) and change both.

## About the calendar view

The calendar is drawn using [FullCalendar](https://fullcalendar.io/),
a free JavaScript library loaded from a CDN. Recurring events using
one of the structured patterns (Weekly / Fortnightly / Monthly / etc.)
appear as individual occurrences, same as in the table. Only the
free-text "Other / describe it" option still shows as a single entry,
since there's no pattern for the app to expand automatically there.

## About the Start Time / End Time fields

Both are optional dropdowns (in 30-minute steps, so people can't
type an unusable value) rather than free text — this is what lets
the app sort events correctly within a day and show a clean "5pm"
label, since sorting real times works reliably but sorting typed
text like "5pm" vs "10am" alphabetically would not. Events without a
start time are treated as "all day" and listed before timed events
on the same date, in both the table and the calendar.

If you'd like a finer or coarser dropdown (e.g. every 15 minutes, or
every hour), change this line near the top of `app.R`:

```r
time_choices <- generate_time_choices()
```

to, for example, `generate_time_choices(interval_minutes = 15)`.

## About the URL field and links

Every submitted URL is shown as a clickable link — in the table, the
calendar popup, and (as a link you can click to check) in the Admin
tab — rather than only ones starting with `http://` or `https://`.
Since every event is reviewed before it's approved, checking a link
is safe is part of that review rather than something the app filters
automatically. The link text itself is still safely escaped so it
can't break out of the page and inject anything else, whatever it
points to.

## Email notifications when someone submits an event

By default the app doesn't send email - you only see new submissions
by checking the Admin tab. To get an email whenever someone submits
an event, set these as environment variables (in Posit Connect Cloud:
your content's settings page, or the "Advanced" step at publish time):

| Variable | What it's for |
|---|---|
| `NOTIFY_EMAIL` | Where to send the notification (your address) |
| `SMTP_USER` | The *sending* email address |
| `SMTP_PASSWORD` | An app password for that address (see note below) |
| `SMTP_PROVIDER` | `gmail`, `outlook`, or `office365` for the common cases |
| `SMTP_HOST` / `SMTP_PORT` | Only needed if you leave `SMTP_PROVIDER` blank (any other provider) |

**Gmail/Outlook/Office365 will reject your normal account password**
for this - you need to create an "app password" specifically for
sending, which requires two-factor authentication to be turned on
for that account first (Gmail: Google Account → Security → 2-Step
Verification → App passwords).

Leaving `NOTIFY_EMAIL` or `SMTP_USER` blank simply switches this off
- nothing else about the app depends on it being configured, and a
problem with your email setup (e.g. a wrong password) can never stop
someone's event submission from going through; it just skips sending
silently. This needs the `blastula` package (added to the
`install.packages()` line above).
