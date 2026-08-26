# The incremental refresh, packaged as a Cloud Run job.
#
# google/cloud-sdk:slim already carries gcloud, bq and python3, which is the
# entire dependency set -- the collectors speak REST over urllib and the model
# is plain SQL run through bq. Nothing here needs pip.
FROM google/cloud-sdk:slim

WORKDIR /app
COPY collect /app/collect
COPY model   /app/model
COPY refresh.sh entrypoint.sh /app/
RUN chmod +x /app/refresh.sh /app/entrypoint.sh /app/collect/*.py

ENTRYPOINT ["/app/entrypoint.sh"]
