`mv gost/ gost_backup`

`git clone https://github.com/1395173231/gost2warp.git gost && cd gost`
```
mkdir -p secrets
chmod 700 secrets

# gost socks 入口的账号密码（格式：username<space>password）
printf "xxx 123456\n" > secrets/gost_socks_auth
chmod 600 secrets/gost_socks_auth
```

`docker compose up -d --build`

`crontab -e`

```
chmod +x looklog.sh 
./looklog.sh 
```

```
curl -x socks5h://xxx:123456@127.0.0.1:1080 https://chatgpt.com/cdn-cgi/trace
```