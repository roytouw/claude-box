# Google Cloud CLI on top of a workspace's image, built by claude-box when .claude-box/gcloud is
# "on". The login lives in a volume per workspace at /gcloud (see bin/claude-box), never in the
# profile's shared home, so other workspaces on the same profile can't use it.
ARG BASE=ghcr.io/roytouw/claude-box:base
FROM ${BASE}

USER root
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
         | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
         > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends \
         google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /gcloud && chown agent:agent /gcloud
USER agent

# gcloud config + login, Application Default Credentials and the kubeconfig that
# `gcloud container clusters get-credentials` writes all live in the per-workspace volume.
ENV CLOUDSDK_CONFIG=/gcloud \
    GOOGLE_APPLICATION_CREDENTIALS=/gcloud/application_default_credentials.json \
    KUBECONFIG=/gcloud/kube/config \
    USE_GKE_GCLOUD_AUTH_PLUGIN=True
