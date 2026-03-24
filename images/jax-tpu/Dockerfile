# Example custom JAX TPU training image
# Build: docker build -t us-central1-docker.pkg.dev/tpu-launchpad-playground/ml-training-images/jax-tpu:latest .
# Push:  docker push us-central1-docker.pkg.dev/tpu-launchpad-playground/ml-training-images/jax-tpu:latest
FROM us-docker.pkg.dev/cloud-tpu-images/jax-ai-image/tpu:latest

# Install ML diagnostics and logging
RUN pip install --no-cache-dir \
    google-cloud-mldiagnostics \
    google-cloud-logging

# Add your dependencies below:
# RUN pip install --no-cache-dir torch transformers datasets

WORKDIR /app
# COPY your_training_script.py .
# CMD ["python", "your_training_script.py"]
