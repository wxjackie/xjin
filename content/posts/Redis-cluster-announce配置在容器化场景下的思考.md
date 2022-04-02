---
title: "Redis的cluster-announce配置在容器化场景的应用思考"
date: 2021-03-30T19:53:16+08:00
draft: false
tags: ["Redis", "云原生", "K8s"]
categories: ["中间件"]
summary: 使用Redis的cluster-announce相关配置，帮助我们简化Redis容器化管理的应用思路。
typora-root-url: ../../static
---

> Redis的`cluster-announce`配置可以帮助我们在Redis Cluster容器化场景下，由于NAT导致默认内部IP无法互相连通，需要走网关或端口转发时使用的配置，引用Redis 5.0官方的配置描述如下：
>
> ```
> ########################## CLUSTER DOCKER/NAT support  ########################
> # In certain deployments, Redis Cluster nodes address discovery fails, because
> # addresses are NAT-ted or because ports are forwarded (the typical case is
> # Docker and other containers).
> #
> # In order to make Redis Cluster working in such environments, a static
> # configuration where each node knows its public address is needed. The
> # following two options are used for this scope, and are:
> #
> # * cluster-announce-ip
> # * cluster-announce-port
> # * cluster-announce-bus-port
> #
> # Each instruct the node about its address, client port, and cluster message
> # bus port. The information is then published in the header of the bus packets
> # so that other nodes will be able to correctly map the address of the node
> # publishing the information.
> #
> # If the above options are not used, the normal Redis Cluster auto-detection
> # will be used instead.
> ```

## 容器化场景下的用途

这组配置是相对比较冷门的，社区[相关issue](https://github.com/redis/redis/issues/2527)也是多机跑Docker部署Redis Cluster时，发现该场景下Redis集群的每个节点需要一个**外部通告地址**，才提出的这个需求，那时Redis 3.2版本已经release了。而且正常线上环境，无论是云主机还是容器化的Pod，都能保证彼此是网络互通的，才会部署Redis Cluster。

但是在容器化的场景中，经过一些场景验证，我发现这个配置可以帮我们简化很多之前管控处理的逻辑。

下面列举一个场景：假设我们用一个`StatefulSet`部署一个3主3从的Redis Cluster，使编号为偶数的Pod（0,2,4）为master，编号为奇数的Pod（1,3,5）为slave

集群组建完成后，对其中一个节点，这里选择1号Pod，发送`cluster nodes`，可以观察集群拓扑如下：

```shell
root@proxy-cluster2-6379-0-1:/data# redis-cli cluster nodes
5d0161fb2ee7dabd5dacb50ad689b2f6a5b9fd9e 10.17.136.37:6379@16379 myself,slave c357283ab9f50917b2ae647603d05dca416a7018 0 1648798492000 1 connected
b3a9205ed85cbf11d84315ab182261fa95697b46 10.17.136.33:6379@16379 slave c11ed6cdc0f15954c6ec2f8db1f0bf53f5005f7c 0 1648798493372 4 connected
c11ed6cdc0f15954c6ec2f8db1f0bf53f5005f7c 10.17.139.14:6379@16379 master - 0 1648798491369 3 connected 0-5461
c357283ab9f50917b2ae647603d05dca416a7018 10.17.139.47:6379@16379 master - 0 1648798492000 2 connected 10923-16383
bc41ca58cfd3dd2bc3c2dd622819b4df8787c879 10.17.139.59:6379@16379 master - 0 1648798491000 5 connected 5462-10922
ab5ec582ae262ff55cbea3afa609736d5ff72737 10.17.180.20:6379@16379 slave bc41ca58cfd3dd2bc3c2dd622819b4df8787c879 0 1648798492370 6 connected
```

这时我们保存该Pod（IP为`10.17.136.37`）的`nodes.conf`，即自动生成的集群拓扑配置文件，然后删掉该Pod。由于Sts的机制，这个Pod会被自动重建，观察到重建后1号Pod的IP变化为`10.17.135.30`。

如果不使用`cluster-announce-ip`配置指明当前Pod地址，重新启动Redis进程时，直接使用之前残留的`nodes.conf`文件的话，会出现如下现象：

![err-condition](/img/redis-cluster-announce-conf/err-condition.png)

残留的`nodes.conf`文件中`myself`行对应的IP地址是`10.17.136.37`，但当前Pod已经被重建，IP变为`10.17.135.50`，直接启动会沿用旧的`nodes.conf`，从本地执行`cluster nodes`，发现`myself`对应的还是旧IP，而从Redis集群中其他节点中执行`cluster nodes`，是Pod真实的IP。

之前的Operator在处理这种情况时，都会将Pod挂掉的节点从集群中`forget`掉并清除遗留的`nodes.conf`，然后在重建后的Pod上拉起Redis进程，执行`cluster meet`重新加入集群，如果角色是slave还要执行`cluster replicate`。

那么`cluster-announce-ip`配置如何帮助我们简化处理这种情况呢？使用`cluster-announce-ip`配置，可以复用遗留的`nodes.conf`启动和加入集群，并且将`myself`对应的IP地址更新为`cluster-announce-ip`，既可以复用`nodes.conf`，又可以确保本地和其他节点的`cluster nodes`对于某一节点的IP记录保证一致，这个过程最小化了Operator的逻辑耦合。

除此之外，`cluster-announce-ip`还可以用作**向K8s外部暴露Redis Cluster服务**使用，比如业务端无法与Redis Pod直接连通，但可以通过LoadBalancer方式访问。那么我们可以用LoadBalancer的sub service指向一个个Redis Pod，这些Pod配置`cluster-announce-ip`为LoadBalancer的sub service地址，这样业务边可通过LoadBalancer的形式使用Redis Cluster。

## 补充说明

- cluster-announce相关配置在4.0之后正式支持，自描述配置文件：https://raw.githubusercontent.com/redis/redis/4.0/redis.conf
- Redis 6.X之后添加了对于TLS的支持，也可以单独配置announce端口，可以参考6.X版本官方配置。

## 参考

- https://github.com/redis/redis/issues/2527
- https://raw.githubusercontent.com/redis/redis/5.0/redis.conf
