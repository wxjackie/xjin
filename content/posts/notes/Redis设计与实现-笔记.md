---
title: "Redis设计与实现-笔记"
date: 2020-11-08T10:42:03+08:00
draft: true
typora-root-url: ../../../static
---

```
基于Redis 3.0源码
```

## 一、数据结构与对象

字符串string、列表list、哈希hash、集合set、有序集合sorted set

### 1. SDS 动态字符串

Redis中的字符串值，比如key，string类型value都是通过自己构建的抽象类型，SDS（简单动态字符串）实现的。源码:`sds.c/sds.h`

```c
struct sdshdr {
    unsigned int len;  // 记录buf数组中已使用字节数量，等于SDS字符串的长度
    unsigned int free; // 记录buf数组中未使用字节数量
    char buf[];
};
```

特点：

- 常数复杂度O(1)获取字符串长度（C字符串需要遍历才行，即O(n)）
- API安全，杜绝缓冲区溢出的问题（C字符串不预先分配内存会缓冲区溢出）
- 减少修改字符串造成的内存重分配，通过空间预分配和懒释放策略（C字符串每次增长和截取都需要内存重分配，否则会缓冲区溢出或内存泄漏）
- 二进制安全，使用len属性作为长度判断依据（C字符串以空字符结尾，因此不能包含空字符，不能保存二进制数据）
- 兼容部分`<string.h>`库中的函数

### 2. Linked List 链表

当一个list类型的key包含了数量较多的元素，或列表中包含的元素都是较长的字符串，Redis就会使用链表作为list的底层实现。源码`adlist.h/adlist.c`

链表被用于list类型、发布与订阅、慢查询、监视器等。

```c
typedef struct listNode {
    struct listNode *prev;
    struct listNode *next;
    void *value;
} listNode;

typedef struct list {
    listNode *head;   // 头节点
    listNode *tail;   // 尾节点
    void *(*dup)(void *ptr); // 节点值复制函数，这三个函数是用于实现多态链表所需的特定类型函数
    void (*free)(void *ptr); // 节点值释放函数
    int (*match)(void *ptr, void *key);  // 节点值对比函数
    unsigned long len;
} list;
```

特点：

- 双向、无环、带表头表尾指针、带长度计数器
- 多态：链表节点用`void*`保存节点值，并且可以为链表设置不同类型特定函数，链表可用于保存各种不同类型的值

### 3. Dict 字典

Redis的数据库就是使用字典来作为底层实现的，除了表示数据库，字典也是hash类型的底层实现之一（当hash包含的键值对比较多，且单个元素都是较长的字符串时）。

Redis字典使用哈希表作为底层实现，一个哈希表有多个哈希表节点，每个哈希表节点保存字典的一个键值对。源码：`dict.h/dict.c`

所使用的的哈希表和哈希表节点结构

![image-20220318170300002](/img/notes/redis-design-dict.png)

```c
typedef struct dictht {
    dictEntry **table; // 哈希表数组，为什么这是个数组，参考：https://www.igiftidea.com/article/14210565837.html
    unsigned long size; // 哈希表大小
    unsigned long sizemask; // 哈希表大小掩码，用于计算索引值，总是等于size-1
    unsigned long used; // 该哈希表已有节点的数量
} dictht;

typedef struct dictEntry {
    void *key; // 键
    union {  // 值
        void *val;
        uint64_t u64;
        int64_t s64;
        double d;
    } v;
    struct dictEntry *next; // 指向下个哈希表节点，形成链表
} dictEntry;
```

Redis中的字典结构

```c
typedef struct dict {
    dictType *type; // 类型特定函数
    void *privdata; // 私有数据
    dictht ht[2]; // 哈希表
    long rehashidx; // 记录rehash进度，没在做rehash该值为-1
    unsigned long iterators; /* number of iterators currently running */
} dict;
```

- type属性是一个指向`dictType`结构的指针，每个`dictType`结构保存了一组用于操作特定类型键值对的函数，Redis会为用途不同的字典设置不同的类型特定函数。type和privdata属性是针对不同类型的键值对，为创建多态字典而设置的。
- privdata属性保存了需要传给那些类型特定函数的可选参数。
- `ht`属性是一个包含两个项的数组，即两个`dictht`哈希表，一般情况下字典只使用`ht[0]`，`ht[1]`只会在对`ht[0]`哈希表进行`rehash`时使用。

将一个键值对添加到字典，会先根据键计算出哈希值，再计算出索引值，将包含新键值对的哈希表节点放到哈希表数组的指定索引处。

```c
// 使用字典设置的哈希函数，计算出key的哈希值，Redis字典默认使用Murmur Hash
hash = dict->type->hashFunction(key);
// 使用sizemask和哈希值，计算出索引值，根据情况不同，使用的可能是ht[0]或ht[1]
index = hash & dict->ht[x].sizemask;
```

Redis的哈希表解决**哈希冲突**采用的是**链地址法**，每个哈希表节点都有一个next指针，多个节点会组成一个单向链表，新节点会添加到表头，因为时间复杂度O(1)

为了让哈希表的负载因子（load factor）维持在合理范围，需要有机制对哈希表的大小进行**扩展或收缩**。大致步骤如下：

- 为`ht[1]`分配空间，如果是扩展，那么`ht[1]`的大小为第一个大于等于`ht[0].used*2`的2的n次方幂
- 如果是收缩，那么`ht[1]`的大小为第一个大于等于`ht[0].used`的2的n次方幂
- 将`ht[0]`上的值rehash到`ht[1]`上，即重新计算哈希值和索引值，放置到`ht[1]`

什么时候进行扩展和收缩呢？

1. 没有在执行`BGSAVE`或`BGREWRITEAOF`，并且负载因子大于1
2. 正在执行`BGSAVE`或`BGREWRITEAOF`，并且负载因子大于5
3. 负载因子小于0.1，会收缩

渐进式hash，每次访问字典时，除了执行指定的操作外，还会顺带将`ht[0]`在`rehashidx`索引上的所有键值对rehash到`ht[1]`，是种分而治之的思想，避免集中rehahs带来的庞大计算量。

### 4. Skip List 跳表

跳表是Redis有序集合的底层实现之一，当有序集包含的元素数量较多，或集合中元素的成员是比较长的字符串时，会采用跳表实现。Redis只在两个地方用到了跳表：有序集实现和集群节点内部数据结构

Redis跳表的实现用的两个数据结构，`zskiplist`保存跳表信息（表头、表尾、长度等），`zskiplistNode`表示跳表节点，每个跳表节点的层高都是1-32之间的随机数（幂次定律，越大的数出现概率越小）。

![image-20220318165941885](/img/notes/redis-design-skiplist.png)

```c
// server.h/zskiplistNode
typedef struct zskiplistNode {
    sds ele; // 元素
    double score; // 分值
    struct zskiplistNode *backward; // 后退指针
    struct zskiplistLevel {
        struct zskiplistNode *forward; // 前进指针
        unsigned long span; // 跨度，可用来帮助记录rank
    } level[];  // 层
} zskiplistNode;

// server.h/zskiplist
typedef struct zskiplist {
    struct zskiplistNode *header, *tail;  // 表头节点和尾节点
    unsigned long length; // 节点数量
    int level; // 层数最大节点的层数（除去头结点）
} zskiplist;
```

跳表中的节点按照分值大小排序，当分值相同时，按照成员对象的大小进行排序。

### 5. Intset 整数集合

整数集合是Redis集合的底层实现之一，当集合只包含整数值元素且元素数量不多时，会用它作为底层实现。

```c
typedef struct intset {
    uint32_t encoding;  // 编码方式
    uint32_t length; // 集合包含元素数量
    int8_t contents[]; // 保存元素的数组
} intset;
```

intset底层实现是数组，这个数组有序、无重复，在必要时，程序会根据新增数据的类型，改变这个数组的类型（即升级），比如之前全是int16，新增一个int32数字，那么整个数组需要升级。但没有降级。

升级操作给intset带来了灵活性（自适应类型），不必担心类型错误；并且尽可能的节约了内存。

### 6. Ziplist 压缩列表

ziplist是列表键和哈希键的底层实现之一，当列表键只包含少量的项，并且列表项都为小整数值或较短的字符串，Redis就会采用压缩列表作为list的底层实现、

当一个hash只包含少量键值对，并且键值要么是小整数值，要么是长度比较短的字符串，就会用压缩列表作为hash的底层实现。

```c
// ziplist.c/zlentry
typedef struct zlentry {
    unsigned int prevrawlensize;
    unsigned int prevrawlen;
    unsigned int lensize;
    unsigned int len;
    unsigned int headersize;
    unsigned char encoding;
    unsigned char *p;
} zlentry;
```

- 它是为了节约内存而开发的顺序型数据结构
- 向ziplist添加新节点或删除节点，都可能会引发连锁更新，发生空间重分配，最坏复杂度为O(N的二次幂)，但出现频率不高。

### 7. 对象

Redis数据库的每一个键值对的键和值都是一个对象（字符串对象、列表对象、哈希对象、集合对象、有序集对象，基于前面说的数据结构，而不是直接使用那些数据结构，可以针对不同场景使用不同数据结构实现，优化不同场景下的效率）

```c
typedef struct redisObject {  // 位域结构体，指定每个成员占用的位数
    unsigned type:4;  // 类型
    unsigned encoding:4;  // 编码
    unsigned lru:LRU_BITS; /* LRU time (relative to global lru_clock) or
                            * LFU data (least significant 8 bits frequency
                            * and most significant 16 bits access time). */
    int refcount; // 引用计数
    void *ptr; // 指向底层实现数据结构的指针
} robj;
```

每种类型的对象都至少使用了两种不同的编码，如下表（基于3.0）

![image-20220320193344429](/img/notes/redis-design-obj-encoding.png)

比如列表对象包含的元素数较少时，使用ziplist比双向链表更加省内存，并且以连续内存块方式保存的ziplist比双向链表载入缓存（计算机中除了内存还有高速缓存）更快。

#### 字符串对象

字符串对象是Redis五种类型对象中唯一会被其他对象嵌套的对象

- 编码int：string对象保存的是long类型可以表示的整数值
- 编码embstr：字符串值小于等于32字节，sds保存值。
- 编码raw：字符串值大于32字节，sds保存值（raw编码会调用两次内存分配函数分别创建robj和sdshdr，embstr调用一次内存分配函数分配一个连续空间，依次包含robj和sdshdr）

#### 列表对象

编码可以是ziplist、linkedlist；使用ziplist编码需要列表对象同时满足所有字符串元素的长度都小于64字节，且元素数量小于512个，否则为linkedlist，这两个值都是可以配置的：`list-max-ziplist-value`和`list-max-ziplist-entries`

#### hash对象

编码可以是ziplist、hashtable；使用ziplist需要所有键值对的键和值都小于64字节，且键值对个数不超过512个，否则需要使用hashtable编码，也是可配的。

#### 集合对象

编码可以是intset、hashtable；使用intset需要集合保存的所有元素都是整数值，且保存的元素数量不超过512个，否则需要用hashtable编码。

#### 有序集合对象

编码可以是ziplist和skiplist；使用ziplist需要元素数量小于128个，且所有元素都小于64字节，否则需要用skiplist编码。

skiplist编码的有序集合对象使用zset结构作为底层实现，一个zset结构同时包含一个字典和一个skiplist

```c
typedef struct zset {
  zskiplist *zsl
  dict *dict
} zset;
```

同时使用字典和跳表是为了同时使用跳表的范围查找高效率和字典O(1)复杂度查找成员的特性。这两种数据结构都会通过指针来共享相同元素的成员和分值，所以不会产生重复成员和分值，不会因此浪费额外的内存。

#### 对象其他概念

- Redis有类型检查和命令多态，比如DEL、EXPIRE等命令是基于类型的多态，LLEN等命令的区别是基于编码的多态。
- C本身不具备自动内存回收的能力，Redis在自己的对象系统中构建了一个**引用计数**技术实现了内存回收机制，在适当的时候自动释放对象并进行内存回收。
- 除了用于实现引用计数内存回收机制之外，对象的refcount属性还带有对象共享的作用。目前Redis初始化服务时会创建1w个字符串对象，包含0-9999的所有整数值，当需要用这些值时，服务就会用共享对象而不是新建对象。
- 对象通过lru属性记录自己最后一次被访问的时间，可用于计算对象空转时间，用于内存淘汰策略。

## 二、单机数据库

### 9. DB 数据库

Redis所有DB都保存在`server.h/redisServer`结构的db数组中，db数组每个元素都是一个`server.h/redisDb`结构，即一个数据库。

```c
typedef struct redisDb {
    dict *dict;                 /* The keyspace for this DB */
    dict *expires;              /* Timeout of keys with a timeout set */
    dict *blocking_keys;        /* Keys with clients waiting for data (BLPOP)*/
    dict *ready_keys;           /* Blocked keys that received a PUSH */
    dict *watched_keys;         /* WATCHED keys for MULTI/EXEC CAS */
    int id;                     /* Database ID */
    long long avg_ttl;          /* Average TTL, just for stats */
    list *defrag_later;         /* List of key names to attempt to defrag one by one, gradually. */
} redisDb;
```

`redisDb`结构的dict字典保存了数据库中所有键值对，这个字典也叫**键空间（key space）**，也就是用户使用上感知的kv数据库。当使用Redis命令进行读写时，除了读写键空间，还会执行一些额外的维护操作，比如：更新hit和miss次数、更新LRU时间、惰性删除、针对被WATCH的键的dirty处理、数据库通知功能事件处理。

#### 过期处理

- Redis设置过期时间本质上都是`PEXPIREAT`命令，指定key过期的毫秒级时间戳
- `redisDb`结构的`expires`字典保存了所有key的过期时间，也称它为过期字典；key为指向键对象的指针，value为long long类型整数，即毫秒级的过期时间戳。
- Redis过期策略通过惰性删除`db.c/expireIfNeed`和定期删除`server.c/activeExpireCycle`两种配合实现；惰性删除为所有对key的访问，都会先检查其是否过期，如果过期则删除；定期删除会分为多次循环，随机获取一些key进行检查与执行删除，这个定期删除的循环有一定的时间上限。
- Redis过期键不会对RDB和AOF产生影响，AOF删除Key时会追加DEL命令，AOF rewrite时也不会再写入过期的key。
- slave发现过期key不会主从删除，需要等待master发来DEL命令进行删除，尽可能的保证主从一致性。

### 10. RDB持久化

`redisServer`结构中会保存所有用`save`配置的自动保存rdb条件，任意一个条件满足，服务会自动执行BGSAVE

### 11. AOF持久化

- AOF保存所有修改DB的写命令，所有命令都以Redis命令请求协议（纯文本协议）的格式保存
- 命令请求会先到AOF缓冲区中(redisServer->aof_buf)，之后再定期写入并同步到AOF文件
- appendfsync可选always、everysec、no，不同选项对于性能和数据丢失有不同程度的影响。
- AOF重写是通过读取DB中的键值对实现的，不会对原有AOF读取和分析。
- 在执行`BGREWRITREAOF`命令时，Redis会维护一个**AOF重写缓冲区**，它会在子进程创建新AOF文件期间，记录执行的所有写命令，当子进程完成AOF文件创建后，服务会将rewrite buf中所有内容追加到新AOF文件上；最后用新AOF替换旧AOF。

### 12. 事件

Redis服务器是一个**事件驱动**程序，处理文件事件（file event）和时间事件（time event）

- 文件事件：Redis服务通过套接字与客户端连接，文件事件就是对套接字操作的抽象。当套接字变为可应答（acceptable）、可写（writable）和可读（readable），相应的文件事件就会产生。分为`AE_READABLE`读事件和`AE_WRITEABLE`写事件两种。

  时间事件：分为定时事件（只在指定时间执行一次）和周期事件，Redis一般只有`serverCron`函数一个周期事件。

Redis基于Reactor模式开发了自己的网络事件处理器，被称为文件事件处理器（file event handler）；它使用**IO多路复用**程序来同时监听多个套接字，并根据套接字产生的事件类型关联不同的事件处理器。当被监听的套接字准备好应答、读取、写入、关闭等操作时，对应文件事件就会产生，handler就会调用之前关联好的处理器去处理这些事件。

事件调度和执行伪代码：

```c
// ae.c/aeProcessEvents
def aeProcessEvents():
	// 获取到达时间离当前最近的时间事件
	time_event = aeSearchNearestTimer()
  // 计算还有多久到达
  remaind_ms = time_event.when - unix_ts_now()
  if remaind_ms < 0:
  	remaind_ms = 0
  // 根据remaind_ms创建timeval结构
  timeval = create_timeval_with_ms(remaind_ms)
  // 阻塞等待文件事件产生，如果remaind_ms为0，那么会调用后马上返回，不阻塞
  aeApiPoll(timeval)
  
  // 处理文件事件
  processFileEvents()
  // 处理时间事件
  processTimeEvents()
```

Redis文件事件和时间事件为合作关系，会被轮流处理，一般不会发生抢占。时间事件处理一般会被设定时间晚些。

### 13. 客户端

`redisServer`结构中用`clients`链表连接起多个客户端状态，新添加的客户端会被放到链表的末尾。客户端的属性分为两类，通用的属性和特定功能相关的属性。

一个命令从客户端发出经历的具体流程：`redisClient`的输入缓冲区（一个SDS）追加Redis协议字符串形式的命令，服务从input buffer中获取内容并解析命令，将得到的命令和命令参数保存，根据`argv[0]`保存的值，在命令表中查找命令对应的命令实现函数，成功找到`redisCommand`后，将`redisClient`的`cmd`指针指向这个结构。之后服务就可根据`argv`和`cmd`调用命令实现函数，执行指令。

客户端flags属性使用不同标志表示客户端角色，以及客户端当前所处的状态。

输入缓冲区记录了客户端发送的命令请求，缓冲区大小不能超过1GB。

客户端有固定大小缓冲区和可变大小缓冲区两种缓冲区可用，前者大小固定16KB，后者是个链表。如果输出缓冲区超过硬性限制，客户端会被立即关闭；在一定时间内一直高于软性限制，也会被关闭。

两个伪客户端：处理Lua的客户端在Redis初始化时创建，会一直存在到服务关闭；载入AOF的客户端在开始载入时初始化，载入完毕后自动关闭。

### 14. 服务器

- serverCron默认每隔100ms执行一次，主要工作包括：更新服务器状态信息(时间缓存、LRU时钟、估算的OPS)、管理客户端资源和数据库状态、清除过期Key、处理接收的SIGTERM信号、检查并执行持久化操作等。
- Redis服务从启动到能处理请求需要执行以下步骤：初始化服务器状态；载入服务器配置；初始化服务器数据结构；根据AOF和RDB还原数据；启动事件循环。

## 三、多机数据库

### 15. 复制

### 16. Sentinel

### 17. 集群

## 四、独立功能实现

