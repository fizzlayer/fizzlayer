# Supabase Compute builds this directory. The proxy and the sidecars are the
# image CI publishes to Docker Hub as fizzlayer/fizzlayer-hosted-gateway.
# Replace :latest with the sha- tag of the commit you deploy.
# Compute reads the start command from this final stage. The base image's
# ENTRYPOINT is not visible to that check.
FROM fizzlayer/fizzlayer-hosted-gateway:sha-dd3f7cf6959064ac54793443a3e27696bbcef4fe
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/hosted-entrypoint"]
