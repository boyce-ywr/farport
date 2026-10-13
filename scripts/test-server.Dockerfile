FROM ubuntu:22.04
RUN sed -i 's@http://archive.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g; s@http://security.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g; s@http://ports.ubuntu.com/ubuntu-ports/@http://mirrors.aliyun.com/ubuntu-ports/@g' /etc/apt/sources.list \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server tmux python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd \
    && useradd -m -s /bin/bash tester && passwd -d tester \
    && printf '\nPasswordAuthentication no\nPermitRootLogin no\nAllowUsers tester\n' >> /etc/ssh/sshd_config
RUN rm -f /etc/ssh/ssh_host_*key*
CMD ["/bin/sh", "-c", "ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
