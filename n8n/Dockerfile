FROM mwader/static-ffmpeg:latest AS ffmpeg

# Stage 2: Build final n8n image with ffmpeg
FROM n8nio/n8n:latest

USER root
# Copy static ffmpeg binaries from the ffmpeg stage
COPY --from=ffmpeg /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg /ffprobe /usr/local/bin/ffprobe
USER node
