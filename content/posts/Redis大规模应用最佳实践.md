---
title: "Redis大规模应用最佳实践"
date: 2022-03-16T10:57:03+08:00
draft: false
tags: ["Redis", "最佳实践"]
categories: ["中间件"]
summary: 介绍Redis在大规模应用时需要注意的事项和使用建议。
typora-root-url: ../../static
toc:
  auto: false
---

> 自从工作以来，我个人一直专注于Redis相关的公有云、私有云、容器化开发，积累了不少经验，也踩过不少坑。这里根据近期组内的分享和个人经验来做个总结，希望能够通过一篇文章阐明Redis在大规模应用时的最佳实践。

## 1. 架构选型

下面简单介绍Redis常用的、原生的高可用架构模式：**哨兵模式和集群模式**。具体高可用机制的细节和非高可用的模式不在该部分的讨论范围内。

### 哨兵模式

由一组Redis Sentinel管理若干组Redis主从实例，每组Redis主从在哨兵中体现为一个Group，当Master故障，Sentinel会做自动的故障主从切换，将同Group内其中一个可用的Slave提升成Master，满足了基本的高可用要求。基本架构如图所示：

![redis-sentinel-mode](/img/redis-best-practice/redis-sentinel-mode.png)

客户端访问哨兵模式Redis有两种方式，下面都以简单的Jedis客户端举例：

- 使用Jedis类，需要Redis服务方提供出VIP的机制，保证VIP始终指向最新的Master（需要一个额外的管控服务去做这件事，因此对于哨兵模式仍建议使用JedisSentinel）
- 使用JedisSentinel类，客户端配置Redis Sentinel的地址和对应的主从Group名称，即客户端通过Sentinel感知Redis主从，无需引入VIP。

通常，一组Redis Sentinel管理成百上千组Redis主从是没有问题的，但实际线上使用时，可以根据不同租户（如果是云服务商）、不同重要程度的Redis进行分组使用独立的Redis Sentinel组。哨兵模式的缺点是，它本质上还是一个单点结构，不是分布式的，无法支持水平扩展。下面介绍Redis 3.0后官方引入的分布式架构：Redis Cluster。

### 集群模式

`Redis Cluster`是自3.0版本后原生支持的集群化方案，也是目前建议线上使用的模式。

分布式存储中需要提供维护节点元数据信息的机制，常见的元数据维护方式分为：集中式和P2P式，Redis采用的Gossip协议的原理就是节点彼此不断通信交换信息，一段时间后所有的节点都会知道集群完整信息，Redis Cluster中的Gossip除了交换槽信息，还交换主从状态/节点故障等，Redis Cluster的自动故障切换也是基于此实现的。如下图所示，Redis Cluster可以分为多个分片（一般最少3个），每个分片拥有不同范围的数据槽（slots），分片数是可以伸缩的，即支持水平扩展。

![redis-cluster-mode](/img/redis-best-practice/redis-cluster-mode.png)

客户端访问Redis Cluster有两种方式，仍以Jedis举例：

- 使用JedisCluster类：这个类是Jedis专为RedisCluster设计的Smart Client，使用时配置Redis Cluster中多个节点的地址信息，客户端会自动感知到整个Redis集群的拓扑，包括缓存槽分布，确定key和分片的映射关系。
- 使用Jedis类：对于一些老的业务仍使用单点模式客户端（如Jedis），但由于容量问题Redis需要更换为Redis Cluster。这种情况需要为Redis Cluster前置Proxy + LoadBalance服务，便可以屏蔽集群拓扑、用单点的模式向外提供服务。社区中有多个可用的Proxy，比如RedisLabs提供的`Redis Cluster Proxy`（仍在alpha阶段）、`Envoy`的`Redis Cluster Filter`等，这里不再赘述。

Redis Cluster的缺点是，人工运维较复杂，集群规模越大，内部通信网络成本越高；客户端需要采用Smart Client（即能够识别集群拓扑的客户端）或加入代理层（Proxy）。但是相较于Redis Cluster提供的水平扩展和自治能力，这些问题还是可以接受的，Redis Cluster仍是目前推行的主流模式。

## 2. 内存管理

Redis是高性能、纯内存的kv缓存数据库，内存相较于磁盘是比较昂贵的存储介质，它的存储容量往往是比较有限的，因此在使用上需要格外关注内存管理。

### 避免内存浪费

- 建议Redis只保存热数据，即将高频访问数据放到Redis，低频访问数据仍使用MySQL、MongoDB等持久化存储。
- 数据要设置过期时间，避免大量key造成泄漏，定期对RDB文件进行离线分析生成报表，及时发现不合理的使用方式。
- 对于必要的、且较大的key，可以考虑选择合适的压缩算法进行压缩后再写入Redis，源数据的压缩/解压需要客户端额外的CPU资源开销，需要业务对Redis内存和业务CPU资源做权衡决定。

### 内存碎片处理

内存碎片的产生原因：内存分配器的策略一般都是每次分配固定的大小而不是完全按应用申请的内存大小分配，这样可以减少内存分配的次数；Redis的Key大小是不定的，对于Key的修改和删除会让原先使用的内存位置成为碎片。

如何检查内存碎片率：使用`INFO`命令在`Memory`部分可以看到Redis内存相关信息，`mem_fragmentation_ratio`就是内存碎片率。一般在处于1-1.5之间时都属于合理情况；如果小于1，可能是分配的内存大于实际内存，启用了虚拟内存（Swap），性能会严重下降，线上要避免这种情况，下面会提及；如果大于2，一般需要关注并处理。

内存碎片率高的典型场景：数据被强制剔除、连续空间的数据结构修改缩短、短时间大量删除key。

如何处理内存碎片：Redis 4.X以上的版本提供了自动内存碎片清理的功能和相关配置，也可以使用`memory purge`命令手动发起清理，需要注意的是，**内存碎片整理执行时会导致访问时延增大**，建议在业务低峰执行清理，具体配置项如下：

```shell
# 启用内存碎片整理
activedefrag yes
# 开始执行内存碎片清理的碎片大小最小阈值
active-defrag-ignore-bytes 100mb
# 碎片占OS给Redis分配的内存10%时，开启执行清理，达到100%开始尽最大努力清理
active-defrag-threshold-lower 10
active-defrag-threshold-upper 100
# 自动清理过程所用 CPU 时间的比例不低于10%，不高于70%，为了不影响Redis正常服务
active-defrag-cycle-min 25
active-defrag-cycle-max 75
```

### 避免不均衡问题

有时候我们可以通过监控或者命令发现，Redis Cluster不同分片的内存用量差距很大，然而我们的数据槽一般是均分到各个分片的，这种情况可能是由**大key、过多使用hash tag**导致的。

首先要避免使用大key：

- string类型可以对value进行拆分，保证value在一定范围内，比如1KB
- 集合类型（list、hash、set）要避免元素（item）过多，一般要求元素个数尽量不要过万，key大小不能达到MB级别。

hash tag是Redis Cluster的一个功能，使用大括号`{}`，指定key只计算大括号内字符串的哈希，从而将不同key插入到同一个数据槽，`CLUSTER KEYSLOT`命令可以算出ke对应的数据槽，所以可以检查hash tag效果如下：

```shell
127.0.0.1:6379> CLUSTER KEYSLOT aaa
(integer) 10439
127.0.0.1:6379> CLUSTER KEYSLOT xjin{aaa}
(integer) 10439
127.0.0.1:6379> CLUSTER KEYSLOT xjin{aaa}123
(integer) 10439
```

因此过多使用hash tag会导致数据倾斜，需要根据情况，在必要的情况才使用hash tag。

## 3. 性能

性能方面要考量的维度较多，比如大key、慢查询、热Key、集中过期等问题，还有一些使用方式上的优化。

### 大key

避免使用大key，这个在内存部分也提过了，大key严重时会导致Redis阻塞，触发故障主从切换。大key包括元素大小过大和集合类型元素类型元素过多的情况。同时**大key清理时要使用Redis的lazy-free机制延迟删除**，防止直接同步删除阻塞Redis（淘汰也是同理，可开启`lazyfree-lazy-eviction`规避）。

对于hash类型的大key，哈希扩容需要底层的dict结构扩容，dictExpand是指数扩容，后续扩容代价越大，这个对于内存和性能都会有影响。

发现大key可以使用`redis-cli`的`bigkey`选项（对于集合类型只能列出元素数，无法知晓真实大小，不过一般知道元素个数也就够了）；也可以使用`redis-exporter`通过`SCAN`命令定期执行key扫描任务，目前我们的产品已经通过增强`redis-exporter`支持了这个能力。

### 慢查询

时间复杂度高的命令、集合对象整存整取可能会导致触发慢查询，比如`HGETALL、SMEMBERS、LREM、ZUNION`等命令，慢查询可以通过`SLOWLOG GET`命令发现。有两个慢查询相关的配置：

```shell
# 执行时间超过10000微秒（10ms）记录为慢日志
slowlog-log-slower-than 10000
# 慢日志记录条数
slowlog-max-len 128
```

### 热key处理

热key问题是指，客户端对于个别key频繁访问，热key所在Redis实例CPU飙升的问题。这种问题属于不恰当的使用方式导致的，不能通过Redis服务端扩展解决，需要业务将热key打散成多个key，以便让他们均匀分布到Redis Cluster的多个分片上均衡压力。

发现热key问题可以使用`OBJECT`命令检查具体key的信息、也可以通过`redis-cli`的`hotkeys`选项，但该选项依赖于Redis设置`maxmemory-policy`（淘汰策略）为`allkeys-lfu`，采用这种淘汰策略会记录key的最近访问时间和概率逻辑计数。

### 避免集中过期

过期检查有`ACTIVE_EXPIRE_CYCLE_FAST`和`ACTIVE_EXPIRE_CYCLE_SLOW`两种

正常情况下会通过SLOW方式触发过期，扫描采样过期比例超过10%，升级成FAST方式进行轮询扫描，FAST扫描会在每次事件循环都会触发，单次执行限时1ms。下面是我们碰到过的业务集中key过期的案例：0点时key数量会从4000w+骤减到300w，FAST扫描清理期间CPU占用升高，正常请求受影响，时延升高。

![image-20220408162457999](/img/redis-best-practice/key-expire.png)

### key剔除问题

占用内存超过maxmemory后，新写入数据会触发key强制淘汰，容易出现访问抖动。需要业务评估是否Redis存放的数据是否都是热数据，可以进行RDB离线分析明确Redis存储的内容，是否有一些冷数据不必要存入Redis；如果评估确实是容量需求，可以对Redis进行水平扩容（加分片）解决。

### Pipeline

如果有批量向Redis灌数据的需求，可以考虑使用Pipeline，可以有效减少网络交互次数，获得成倍的吞吐量性能提升。

单次pipeline不宜过大，比如Jedis客户端默认缓冲区8KB，如果客户端处理不及时，会导致Redis服务的`client-output-buffer`堆积，可能会触发Redis服务端主动断开客户端连接。

对于Redis Cluster使用Pipeline目前比较麻烦，需要保证单个Pipeline的key分布在相同分片，如果业务有需求可以在客户端做能力增强，将Key分组后用多条Pipeline写入不同的Redis Cluster分片。

## 4. 部署、运维与安全

### 容量评估和规划

内存资源：

- 容量评估要做出提前量，集群部署时要预估至少半年内的业务用量增长。
- 虚拟机部署Redis需要预留最少40%内存，用于承载客户端缓冲区、CopyOnWrite缓冲、内存碎片。也可以用于紧急情况下的垂直扩容，直接热配置maxmemory生效。
- 如果是容器化（物理机多应用混部），需要配置资源监控，关注整台物理机的内存水位，超过90%或空余小于20GB就需要关注了。

CPU资源：

- 至少分配2核CPU资源，防止BIO线程或fork进程资源竞争。
- 可以配置CPU Affinity（绑核）防止上下文频繁切换，提高性能。

磁盘：

- 至少分配最大内存规格的3倍（由于磁盘比内存廉价很多，这点其实是很容易做到的），并且根据AOF持久化参数适当调整。

### 安全

- 不要暴露端口到公网，bind绑定内网网卡
- Redis必须配置密码
- 推荐配置非标准端口，避免端口扫描工具发现
- rename高危命令，FLUSHDB/FLUSHALL/KEYS/SAVE/CONFIG

### 需要关注的配置项

- 配置`tcp-keepalive`防止连接泄漏，默认300s，探测客户端宕机或者网络中断导致的失效对端，将其主动关闭。还有一个`timeout`参数，它是对于空闲的客户端一定时间无请求后有服务端主动断开，这个操作可能会导致客户端异常，一般不使用。
- 大并发场景下调大`tcp-backlog`配置（受限于OS的参数`net.core.somaxconn`和`net.ipv4.tcp_max_syn_backlog`）
- 集群模式下`cluster-require-full-coverage`设置为`no`，默认值是`yes`，会导致Redis Cluster在有负责的数据槽的分片宕机（没有slave可提主）后，整个集群都无法访问。
- 视情况调大`repl-backlog-size`和`client-output-buffer-limit`；`repl-backlog-size`生产环境可调整到128mb，避免大流量下网络闪断的全量同步；调大`client-output-buffer-limit`中的`slave`部分，可以避免大流量情况下的output buffer溢出，导致复制中断，频繁触发全量同步。下图为Redis全量同步和部分同步的对照图。

  ![redis-sync-mode](/img/redis-best-practice/redis-sync-mode.png)

### 持久化

对于虚拟机或物理机部署Redis，建议采用AOF本地持久化，在磁盘空间足够的情况下，可以调大AOF重写间隔，减少fork次数。

```shell
# 当AOF文件大小的增长超过原大小100%时开始重写
auto-aof-rewrite-percentage 100%
# 当AOF文件大小大于该配置值时自动开启重写
auto-aof-rewrite-min-size 256mb
```

视情况关闭RDB自动持久化（配置文件写入`save ""`即可），因为RDB持久化需要fork子进程，fork操作本身是在主线程执行的，如果fork操作本身耗时长，也会导致其他正常请求延迟。fork会涉及到复制大量链接对象，一个24 GB的大型Redis 实例需要 24GB / 4kB * 8 = 48 MB的页表。执行 bgsave 时，这将涉及分配和复制48MB内存。

经过我们的验证，5GB内存redis fork操作耗时50ms+， 10GB内存redis fork操作耗时100ms+。所以建议单个Redis实例的内存尽量控制在8GB以下，容量问题交给水平扩展来解决。

### 关闭透明大页、Swap

常规的内存页是按照4 KB来分配，Linu 内核从2.6开始支持内存大页机制，该机制支持2MB大小的内存页分配，可能导致Redis时延升高和异常内存消耗。

当生成RDB快照的过程中，Redis采用写时复制（CopyOnWrite）技术使得主线程依然可以接收客户端的写请求。当数据被修改的时候，Redis会复制一份这个数据，再进行修改。启用内存大页，生成RDB期间，即使客户端修改的数据只有 50B 的数据，Redis 需要复制 2MB 的大页。当写的指令比较多的时候就会导致大量的拷贝，导致性能变慢。

关闭内存大页命令：`echo never > /sys/kernel/mm/transparent_hugepage/enabled`

Swap是操作系统里将内存数据在内存和磁盘间来回换入和换出的机制，涉及到磁盘的读写。

> 当某进程向OS请求内存发现不足时，OS会把内存中暂时不用的数据交换出去，放在SWAP分区中，该过程称为SWAP OUT。
>
> 当某进程又需要这些数据且OS发现还有空闲物理内存时，又会把SWAP分区中的数据交换回物理内存中，该过程称为SWAP IN。

当Redis 使用了比可用内存更多的内存时，会触发使用Swap。我们线上一般要关闭Swap，可以使用`swapoff`命令关闭，Redis内存满了应该评估数据是否可以清理、是否需要扩容，而不是使用Swap。

### Redis Cluster相关

Redis Cluster水平扩缩容，需要进行数据迁移，使得Redis分片均分数据槽。在线数据均衡时间较长，达到几个小时以上也是比较常见的，数据迁移期间，对于迁移中的slots的key，访问时延会升高，这也是正常的，一般情况业务是可以接受的。但也有以下几点需要注意：

- 控制key迁移的Pipeline数量，减小数据迁移对正常请求的影响。
- 迁移前确认是否存在大key，这可能会导致阻塞、迁移失败甚至主从切换。

对于大规模的Redis Cluster集群，还要慎用`cluster nodes`命令。这个命令的时间复杂度为163794*O(n)，n为分片数，对于大集群损耗更加严重，然而我们在监控和客户端会经常使用此命令获取集群拓扑和节点状态。Redis 6.2版本对此命令复杂度做了优化。

在Redis Cluster运维中，可能会出现故障节点未被完全从集群拓扑中清除的情况，比如各种原因导致的某个Redis节点`CLUSTER FORGET`失败，会导致集群信息中周期性出现`handshake`状态节点，集群内部Gossip协议会将失败的节点传播给其他节点，其他节点收到后会尝试和失败节点建立连接，所以会周期性出现`handshake`。这种情况需要确保所有节点`CLUSTER FORGET`掉已失效节点的ID。

## 5. 容器化

Redis容器化（Redis On K8s）相关的开发也是我目前的主要工作。基于Kubernetes强大的编排能力和通用的资源对象，我们采用Kubernetes Operator的模式开发了Redis Operator，提供自动化的Redis高可用部署、故障自愈、自动化运维、平滑扩展的能力。

相比于云主机虚拟化以及自建中间件而言，Redis容器化具有更优秀的性能、更节约的成本、更轻量的资源管理、更灵活的调度策略、更快速的故障恢复能力，以及更强的系统自愈能力。

详细信息可以跳转我们的官网了解：[网易数帆-轻舟中间件](https://sf.163.com/product/paas)

## 6. 业务侧

> 目前我个人的经验主要是面向Redis的优化、管控、运维，在使用上的经验广度还不够，下面根据与业务沟通了解、网络资料学习的情况做简要的梳理，后续将持续补充和完善Redis高效的使用方式。

### 双写一致性

业务上使用Redis都会需要考虑，如何保证数据库和缓存中的一致性的问题。最简单常用的方式就是Cache Aside模式，下面简要介绍下这种模式的读写流程。

读请求流程：

1. 如果命中缓存，直接返回缓存数据，请求结束
2. 如果未命中缓存，从数据库读取数据，并将读到的数据写入缓存，然后返回。

写请求流程：先更新数据库，然后删除缓存中的对应数据。

这个模式的好处是，业务侧对于缓存只有`SET`和`DELETE`两种抽象操作，它们都是幂等的操作（UPDATE就是典型的非幂等），避免缓存到数据库中间的链路出现并发不一致问题。

Cache Aside模式还要考虑DELETE失败的问题，本质上这还是非原子操作的事务问题，要想彻底解决还是需要引入分布式锁或分布式事务的解决方案，比如**RedLock、引入队列异步淘汰**，甚至根据业务评估。这些问题也可能都不存在，一致性程度和性能之间的权衡，完全应由业务评估决定。

### 分布式锁

关于Redis分布式锁的解决方案很多，我个人主要经验在优化、管控侧，业务侧了解的相对较少，经过社区中的学习，下面介绍两个方案

方案一：`SET lock_key $unique_id EX $expire_time NX`

- `$unique_id`指当前线程的UID，`$expire_time`为锁过期时间，可以单独开启一个守护线程对锁进行过期检查和自动续期。（如果有可重入锁的需求，可以使用hash结构）
- 为了让检查时释放锁的GET和DELETE为原子操作，可以通过Lua脚本实现。

方案二：红锁（RedLock）具体可参考：[Distributed Locks with Redis](https://redis.io/docs/reference/patterns/distributed-locks/)

红锁需要多个独立的Redis实例，因为单个Redis是有丢失数据导致锁失效（Redis主从切换本身也会丢失数据），下面以5个Redis实例组成的红锁对主要操作进行简单说明：

1. 释放锁：Lua 脚本，先 GET 判断锁是否归属自己，再 DEL 释放锁
2. 客户端依次向这 5 个 Redis 实例发起加锁请求（用方案一讲到的 SET 命令），且每个请求会设置超时时间（毫秒级，要远小于锁的有效时间），如果某一个实例加锁失败（包括网络超时、锁被其它人持有等各种异常情况），就立即向下一个 Redis 实例申请加锁
3. 如果客户端从 >=3 个（大多数）以上 Redis 实例加锁成功，则再次获取「当前时间戳T2」，如果 T2 - T1 < 锁的过期时间，此时，认为客户端加锁成功，否则认为加锁失败
4. 加锁成功，去操作共享资源（例如修改 MySQL 某一行，或发起一个 API 请求）
5. 加锁失败，向「全部节点」发起释放锁请求（前面讲到的 Lua 脚本释放锁）

一般的场景下，个人认为方案一就足够了，红锁的实施成本很高。如果有对于性能要求不高、强一致性的锁需求，可以考虑使用ZooKeeper。

### 巧用数据结构

Redis的基础结构的简单使用场景如下：

- `list`：消息队列（`lpush`、`brpop`）、内容列表
- `set`：作为实体的标签、社交平台的关注/被关注等有对于交集（`sinter`）需求的场景。
- `hash`：保存对象实体信息、分布式可重入锁（Redission的做法）
- `zset`：排行榜（`zinterstore`实现多维度聚合）

这些场景网络上资料很多，这里不再赘述，下面介绍一些进阶的数据结构或模块用途。

使用**GEO功能**。可以实现地理位置相关业务，Redis的GEO功能是基于`zset`和`geohash`实现的。

添加地理位置信息：`geoadd key longitude latitude member [longitude latitude membe ...]`

`longitude`、`latitude`、`member`分别为经度、维度、成员名。比如添加北京的位置：`geoadd cities 116.28 39.55 beijing`

- 获取地理位置：`geopos key member [member ...]`
- 获取两个地理位置的距离：`geodist key member1 member2 [unit]`，unit单位可以选择m、km等。
- 获取指定范围能的地址位置集合：`georadius key longitude latitude radiusm`，该命令参数较多，使用时请查阅[Redis GEO官方文档](https://redis.io/commands/georadius/)
- 获取geohash：`geohash key member [member ...]`，将位置转换成字符串（采用前缀匹配算法），字符串越长位置越精确，GEO功能的一些位置排序就是依赖`geohash`和`zset`实现的。

使用**Bitmap实现用户状态记录**，参考该文章：[巧用 Bitmap 实现亿级数据统计](https://segmentfault.com/a/1190000040177140)

使用`Hyperloglog`高效（非常节省内存）统计总数，参考该文章：[巧用 Redis Hyperloglog，轻松统计 UV 数据](https://segmentfault.com/a/1190000020523110)

### 避免缓存击穿、穿透

- 缓存击穿：某个热点Key的失效，在这个key失效的瞬间，持续的大并发请求直接打到数据库。
- 缓存穿透：指不断请求**缓存和数据库中都没有的数据**，每次请求都要到数据库去，可能会导致短时间内大量请求都打到数据库上，导致数据库压力升高。

避免缓存击穿的方案：

1. 引入互斥锁，只允许一个线程去请求数据库和重建缓存，其他请求将循环等待直到从Redis中能获取数据。
2. 热点Key设置为“永不过期”，即要么不设置过期时间，要么由工作线程定期延长过期时间。
3. 业务代码实现SingleFilght模式（本质上也是一种互斥锁）

避免缓存穿透的方案：

1. 对于在DB获取不到数据的Key，缓存一个空对象，设置较短的过期时间，可以缓和DB的压力（需要业务考虑数据不一致的问题）
2. 使用布隆过滤器。
