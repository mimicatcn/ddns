# Cloudflare DDNS 动态域名解析更新脚本

Cloudflare DDNS 一键部署脚本，自动检测公网 IP 变化并更新 Cloudflare DNS 记录。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mimicatcn/ddns/main/ddns.sh)
```

安装过程中按提示输入：
- API Token
- Zone ID
- 解析域名
- 是否开启小黄云代理

安装完成后自动运行，每 5 分钟检查一次 IP 变化。

## 系统要求

- Debian / Ubuntu
- 需要 root 权限
