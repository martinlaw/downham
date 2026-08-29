# Packages the What's Going Downham Shiny app into a container that
# Render (or any Docker-based host) can run.

FROM rocker/r-ver:4.4.1

# System libraries some of the R packages below need to compile from
# source (libcurl/openssl for blastula's email sending, libxml2 for a
# couple of bslib's dependencies).
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl-dev \
    libcurl4-openssl-dev \
    libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# R packages the app needs. This step is the slow part of the build
# (10-20 minutes is normal, since it compiles from source) - it only
# reruns when this line changes, so later builds that only touch
# app.R are much faster.
RUN R -e "install.packages(c('shiny', 'DT', 'DBI', 'RSQLite', 'dplyr', 'lubridate', 'bslib', 'blastula'), repos = 'https://cloud.r-project.org')"

WORKDIR /app
COPY app.R /app/app.R

# Render tells the container which port to listen on via the PORT
# environment variable; 10000 is Render's documented default if it
# isn't set. The app must listen on 0.0.0.0, not just localhost, to
# be reachable from outside the container.
ENV PORT=10000
EXPOSE 10000

CMD ["R", "-e", "shiny::runApp('/app', host = '0.0.0.0', port = as.integer(Sys.getenv('PORT', '10000')))"]
