FROM grafana/grafana-oss:12.4.3

USER root
# Pinned: the BigQuery plugin declares a version range and 12.4.3 is inside it.
# The BigQuery datasource is a Grafana Labs plugin (Apache-2.0) but is not
# bundled, so install it at build time rather than relying on runtime plugin
# download -- Cloud Run instances are ephemeral and may have no egress budget
# for a cold-start download.
RUN grafana cli plugins install grafana-bigquery-datasource
USER grafana

COPY provisioning/datasources /etc/grafana/provisioning/datasources
COPY provisioning/dashboards/dashboards.yaml /etc/grafana/provisioning/dashboards/
COPY dashboards /etc/grafana/provisioning/dashboards/json

# Cloud Run sends traffic to $PORT and terminates TLS in front, so Grafana runs
# plain HTTP and must be told its public root URL for redirects to work.
ENV GF_SERVER_HTTP_PORT=8080 \
    GF_SERVER_ROOT_URL=%(protocol)s://%(domain)s/ \
    GF_ANALYTICS_REPORTING_ENABLED=false \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_USERS_ALLOW_SIGN_UP=false
EXPOSE 8080
