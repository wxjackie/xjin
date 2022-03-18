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
    dictEntry **table; // 哈希表数组
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





