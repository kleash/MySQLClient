# An SSH server that accepts only the test key (testenv/.keys/id_test.pub,
# made by testenv/run-tests.sh) and forwards TCP: the "bastion" in front of
# the private database.
FROM alpine:3.20
RUN apk add --no-cache openssh-server \
    && adduser -D -s /bin/sh tunnel \
    && passwd -u tunnel \
    && ssh-keygen -A \
    # sshd keeps the first value it reads, and the Include at the top of
    # sshd_config reads this before Alpine's own `AllowTcpForwarding no`.
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'AllowTcpForwarding yes' \
        > /etc/ssh/sshd_config.d/test.conf
COPY --chown=tunnel:tunnel id_test.pub /home/tunnel/.ssh/authorized_keys
RUN chmod 700 /home/tunnel/.ssh && chmod 600 /home/tunnel/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
