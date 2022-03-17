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
    dictType *type;
    void *privdata;
    dictht ht[2];
    long rehashidx; /* rehashing not in progress if rehashidx == -1 */
    unsigned long iterators; /* number of iterators currently running */
} dict;
```



