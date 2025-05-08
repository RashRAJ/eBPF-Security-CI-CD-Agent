FROM ghcr.io/actions/actions-runner:latest

# Install dependencies
RUN sudo apt-get update && sudo apt-get install -y wget curl

# Download and install kntrl
RUN wget -q https://github.com/kondukto-io/kntrl/releases/download/v0.1.3/kntrl && \
    chmod +x kntrl && \
    sudo mv kntrl /usr/local/bin/

# Create startup script
RUN echo '#!/bin/bash\n\
sysctl -w kernel.unprivileged_bpf_disabled=0 || true\n\
/usr/local/bin/kntrl start --mode=trace \
  --allowed-hosts=download.kondukto.io,github.com \
  --allow-github-meta=true \
  --output-file-name=/tmp/kntrl_report.out \
  --verbose &\n\
exec /home/runner/run.sh' > /start-with-kntrl.sh && \
    chmod +x /start-with-kntrl.sh

CMD ["/start-with-kntrl.sh"]