install_ssl_letsencrypt() {
  sed -i 's/tryWebRTCFirst="false"/tryWebRTCFirst="true"/g' /var/www/damine-xyz/client/conf/config.xml

  if ! grep -q $HOST /usr/local/damine-xyz/core/scripts/damine-xyz.yml; then
    bbb-conf --setip $HOST
  fi

  mkdir -p /etc/nginx/ssl

  need_pkg letsencrypt

  if [ ! -f /etc/nginx/ssl/dhp-4096.pem ]; then
    openssl dhparam -dsaparam  -out /etc/nginx/ssl/dhp-4096.pem 4096
  fi

  if [ ! -f /etc/letsencrypt/live/$HOST/fullchain.pem ]; then
    rm -f /tmp/damine-xyz.bak
    if ! grep -q $HOST /etc/nginx/sites-available/damine-xyz; then  # make sure we can do the challenge
      cp /etc/nginx/sites-available/damine-xyz /tmp/damine-xyz.bak
      cat <<HERE > /etc/nginx/sites-available/damine-xyz
server {
  listen 80;
  listen [::]:80;
  server_name $HOST;

  access_log  /var/log/nginx/damine-xyz.access.log;

  # damine-xyz landing page.
  location / {
    root   /var/www/damine-xyz-default;
    index  index.html index.htm;
    expires 1m;
  }

  # Redirect server error pages to the static page /50x.html
  #
  error_page   500 502 503 504  /50x.html;
  location = /50x.html {
    root   /var/www/nginx-default;
  }
}
HERE
      systemctl restart nginx
    fi

    if ! letsencrypt --email $EMAIL --agree-tos --rsa-key-size 4096 --webroot -w /var/www/damine-xyz-default/ -d $HOST --non-interactive certonly; then
      cp /tmp/damine-xyz.bak /etc/nginx/sites-available/damine-xyz
      systemctl restart nginx
      err "Let's Encrypt SSL request for $HOST did not succeed - exiting"
    fi
  fi

  cat <<HERE > /etc/nginx/sites-available/damine-xyz
server {
  listen 80;
  listen [::]:80;
  server_name $HOST;

  listen 443 ssl;
  listen [::]:443 ssl;

    ssl_certificate /etc/letsencrypt/live/$HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOST/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers "ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:ECDH+3DES:DH+3DES:RSA+AESGCM:RSA+AES:RSA+3DES:!aNULL:!MD5:!DSS:!AES256";
    ssl_prefer_server_ciphers on;
    ssl_dhparam /etc/nginx/ssl/dhp-4096.pem;

  access_log  /var/log/nginx/damine-xyz.access.log;

   # Handle RTMPT (RTMP Tunneling).  Forwards requests
   # to Red5 on port 5080
  location ~ (/open/|/close/|/idle/|/send/|/fcs/) {
    proxy_pass         http://127.0.0.1:5080;
    proxy_redirect     off;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;

    client_max_body_size       10m;
    client_body_buffer_size    128k;

    proxy_connect_timeout      90;
    proxy_send_timeout         90;
    proxy_read_timeout         90;

    proxy_buffering            off;
    keepalive_requests         1000000000;
  }

  # Handle desktop sharing tunneling.  Forwards
  # requests to Red5 on port 5080.
  location /deskshare {
     proxy_pass         http://127.0.0.1:5080;
     proxy_redirect     default;
     proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
     client_max_body_size       10m;
     client_body_buffer_size    128k;
     proxy_connect_timeout      90;
     proxy_send_timeout         90;
     proxy_read_timeout         90;
     proxy_buffer_size          4k;
     proxy_buffers              4 32k;
     proxy_busy_buffers_size    64k;
     proxy_temp_file_write_size 64k;
     include    fastcgi_params;
  }

  # damine-xyz landing page.
  location / {
    root   /var/www/damine-xyz-default;
    index  index.html index.htm;
    expires 1m;
  }

  # Include specific rules for record and playback
  include /etc/damine-xyz/nginx/*.nginx;

  #error_page  404  /404.html;

  # Redirect server error pages to the static page /50x.html
  #
  error_page   500 502 503 504  /50x.html;
  location = /50x.html {
    root   /var/www/nginx-default;
  }
}
HERE

  cat <<HERE > /etc/cron.daily/renew-letsencrypt
#!/bin/bash
/usr/bin/letsencrypt renew >> /var/log/letsencrypt/renew.log
/bin/systemctl reload nginx
HERE
  chmod 755 /etc/cron.daily/renew-letsencrypt

  # Configure rest of damine-xyz Configuration for SSL
  sed -i "s/<param name=\"wss-binding\"  value=\"[^\"]*\"\/>/<param name=\"wss-binding\"  value=\"$IP:7443\"\/>/g" /opt/freeswitch/conf/sip_profiles/external.xml

  sed -i 's/http:/https:/g' /etc/damine-xyz/nginx/sip.nginx
  sed -i 's/5066/7443/g'    /etc/damine-xyz/nginx/sip.nginx

  sed -i 's/damine-xyz.web.serverURL=http:/damine-xyz.web.serverURL=https:/g' $SERVLET_DIR/WEB-INF/classes/damine-xyz.properties

  sed -i 's/jnlpUrl=http/jnlpUrl=https/g'   /usr/share/red5/webapps/screenshare/WEB-INF/screenshare.properties
  sed -i 's/jnlpFile=http/jnlpFile=https/g' /usr/share/red5/webapps/screenshare/WEB-INF/screenshare.properties

  sed -i 's|http://|https://|g' /var/www/damine-xyz/client/conf/config.xml

  yq w -i /usr/local/damine-xyz/core/scripts/damine-xyz.yml playback_protocol https
  chmod 644 /usr/local/damine-xyz/core/scripts/damine-xyz.yml 

  if [ -f /var/lib/tomcat7/webapps/demo/bbb_api_conf.jsp ]; then
    sed -i 's/String damine-xyzURL = "http:/String damine-xyzURL = "https:/g' /var/lib/tomcat7/webapps/demo/bbb_api_conf.jsp
  fi

  if [ -f /usr/share/meteor/bundle/programs/server/assets/app/config/settings.yml ]; then
    yq w -i /usr/share/meteor/bundle/programs/server/assets/app/config/settings.yml public.note.url https://$HOST/pad
  fi

  # Update Greenlight (if installed) to use SSL
  if [ -f ~/greenlight/.env ]; then
    damine-xyz_URL=$(cat $SERVLET_DIR/WEB-INF/classes/damine-xyz.properties | grep -v '#' | sed -n '/^damine-xyz.web.serverURL/{s/.*=//;p}')/damine-xyz/
    sed -i "s|.*damine-xyz_ENDPOINT=.*|damine-xyz_ENDPOINT=$damine-xyz_URL|" ~/greenlight/.env
    docker-compose -f ~/greenlight/docker-compose.yml down
    docker-compose -f ~/greenlight/docker-compose.yml up -d
  fi

  # Update HTML5 client (if installed) to use SSL
  if [ -f  /usr/share/meteor/bundle/programs/server/assets/app/config/settings-production.json ]; then
    sed -i "s|\"wsUrl.*|\"wsUrl\": \"wss://$HOST/bbb-webrtc-sfu\",|g" \
      /usr/share/meteor/bundle/programs/server/assets/app/config/settings-production.json
  fi

  TARGET=/usr/local/damine-xyz/bbb-webrtc-sfu/config/default.yml
  if [ -f $TARGET ]; then
    if grep -q kurentoIp $TARGET; then
      yq w -i $TARGET kurentoIp "$IP"
    else
      yq w -i $TARGET kurento[0].ip "$IP"
    fi
    if [ ! -z $INTERNAL_IP ]; then
      yq w -i $TARGET freeswitch.ip $IP
    fi
    chown damine-xyz:damine-xyz $TARGET
    chmod 644 $TARGET
  fi
}