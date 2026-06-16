FROM nginx:stable-alpine

WORKDIR /etc/nginx

RUN rm -rf /etc/nginx/nginx.conf /etc/nginx/conf.d/*

COPY . /etc/nginx/

RUN mkdir -p /var/lib/nginx/tmp && \
    chown -R nginx:nginx /etc/nginx/ /tmp/ /var/lib/nginx && \
    find /etc/nginx -type d -exec chmod 755 {} \; && \
    find /etc/nginx -type f -exec chmod 644 {} \; && \
    nginx -t

USER nginx

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]

