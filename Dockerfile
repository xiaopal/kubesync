FROM alpine:3.7

RUN apk add --no-cache bash coreutils curl openssh-client openssl git findutils && \
	curl -sSL "http://npc.nos-eastchina1.126.net/dl/dumb-init_1.2.0_amd64.tar.gz" | tar -zx -C /usr/local/bin && \
	curl -sSL 'http://npc.nos-eastchina1.126.net/dl/jq_1.5_linux_amd64.tar.gz' | tar -zx -C /usr/local/bin && \
	curl -sSL 'https://npc.nos-eastchina1.126.net/dl/kubernetes-client-v1.9.3-linux-amd64.tar.gz' | tar -zx -C /usr/local && \
	ln -s /usr/local/kubernetes/client/bin/kubectl /usr/local/bin/kubectl

ADD kubesync.sh /usr/local/kubesync.sh
RUN chmod 755 /usr/local/kubesync.sh && ln -s /usr/local/kubesync.sh /usr/local/bin/kubesync

ENTRYPOINT [ "/usr/local/bin/dumb-init" ]
CMD [ "kubesync" ]
