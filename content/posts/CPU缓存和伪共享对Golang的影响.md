---
title: "CPU缓存和伪共享对Golang的影响"
date: 2021-08-26T16:44:03+08:00
draft: false
tags: ["Golang", "底层原理"]
categories: ["Golang"]
summary: 站在CPU高速缓存的角度，分析Cache伪共享在Golang执行效率上的影响。
code:
  maxShownLines: 200
typora-root-url: ../../static
---

> 最近在读文章时发现了一些有趣的底层原理，虽然看似与日常工作没有关联，但还是要知其然知其所以然，在这里简要自行做个笔记和分析。
>
> 现代典型的 CPU 有三级缓存，距离核心越近，速度越快，空间越小。正如内存访问速度远高于磁盘一样，高速缓存访问速度远高于内存。内存一次读写大概需要200个CPU周期(CPU cycles)，而高速缓存一般般情况下只需1个CPU周期。多核处理器（SMP）系统中， 每一个处理器都有一个本地高速缓存。内存系统必须保证高速缓存的一致性。当不同处理器上的线程修改驻留在同一高速缓存中的变量时就会发生假共享(false sharing)，结果就会导致高速缓存无效，并强制更新，进而影响系统性能。

## 基础知识

### CPU缓存体系

![cpu-cache-layer](/img/golang-cpu-cache/cpu-cache-layer.png)

目前最常见的架构是把 L1 和 L2 缓存内嵌在 CPU 核心本地，而把 L3 缓存设计成跨核心共享。越靠近CPU核心的缓存，其容量越小，但是访问延迟越低，比如L1 一般 32k，L2 一般 256k，L3 一般12M。

缓存是由缓存行（Cache Line）组成的，在64位的CPU中典型的一行是64字节。CPU存取缓存都是按行为最小单位操作的。一个Java long型占8字节，所以从一条缓存行上可以获取到8个long型变量。所以如果访问一个long型数组，当有一个long被加载到cache中，将会无消耗地加载了另外7个，所以可以非常快地遍历数组。

### CPU缓存一致性协议-MESI

所有高速缓存与内存，高速缓存之间的数据传输都发生在一条共享的数据总线（Memory controller）上，所有的CPU都能看到这条总线。最简明的缓存一致性思想可以简单阐述为：只要在多核共享缓存行上有数据修改操作，就通知所有的CPU核更新缓存，或者放弃缓存，等待下次访问的时候再重新从内存中读取。

当今大多数Intel处理器使用的缓存一致性协议称为`MESI`，这样命名以表示特定缓存行所处的四种状态：已修改、独占、共享和无效。

- Modified（被修改）：处于这一状态的数据只在本核处理器中有缓存，且其数据已被修改，但还没有更新到内存中。
- Exclusive（独占）：处于这一状态的数据只在本核处理器中有缓存，且其数据没有被修改，与内存一致。
- Shared（共享）：处于这一状态的数据在多核处理器中都有缓存
- Invalid（无效）：本CPU中的这份缓存已经无效了，不能使用

下面介绍一下缓存行在不同场景下的状态变化：

![false-share-example](/img/golang-cpu-cache/false-share-example.png)

- 一开始时，缓存行`Line1`没有加载任何数据，所以它处于`I`状态。数据A和B在内存中位于同一缓存行上。
- `CPU-1`读取数据A，加载到缓存行`Line1`（数据B也被一并加载到该缓存行），`Line1`被标记为`Exclusive`
- `CPU-2`读取数据B，加载到缓存行`Line2`（其实和CPU-1的`Line1`是同一份数据），由于`CPU-1`已经存在了当前数据的缓存行，这两个缓存行被标记为`Shared`状态
- `CPU-1`要修改数据A，此时发现`Line1`的状态还是`Shared`，于是它会先通过总线发送消息给`CPU-2`，通知其将对应的缓存行`Line2`标记为`Invalid`，然后再修改数据A，同时将`Line1`标记为`Modified`
- 这时，`CPU-2`要修改数据B，这时发现`CPU-2`中的`Line2`已经处于`Invalid`状态，且`CPU-1`中的对应缓存行`Line1`处于`Modified`状态。这时`CPU-2`将会通过总线通知`CPU-1`将`Line1`的数据写回内存，然后`CPU-2`再从内存读取对应缓存行到本地缓存行，再去修改数据B，最后通知`CPU-1`将对应缓存行设置为`Invalid`。

### 什么是伪共享

如果上述MESI协议状态变化解读中的最后两个步骤交替发生，就会一直需要访问主存，性能会比访问高速缓存差很多。数据A和B因为归属于一个缓存行 ，这个缓存行中的任意数据被修改后，它们都会相互影响。

因此，当不同CPU上的线程修改驻留在同一高速缓存行（Cache Block，或Cache Line）中的变量时就会发生**伪共享**。 这种现象之所以被称为伪共享，是因为每个线程并非真正共享相同变量的访问权。 访问同一变量或真正共享要求**编程式同步**结构，以确保有序的数据访问。

![img](/img/golang-cpu-cache/cpu-false-shareing.png)

## 规避伪共享

避免伪共享的办法就是**内存填充（Padding）**，可以简单地理解为在两个变量之间填充一定的空间，避免两个变量出现在同一个缓存行内。

下面做个简单的实验，验证下内存填充前后的差异，代码示例如下：

```go
package test

import (
	"sync"
	"testing"
)

const M = 1000000
const CacheLinePadSize = 64

type SimpleStruct struct {
	n int
}

type PaddedStruct struct {
	n int
	_ CacheLinePad
}

type CacheLinePad struct {
	_ [CacheLinePadSize]byte
}

func BenchmarkStructureFalseSharing(b *testing.B) {
	structA := SimpleStruct{}
	structB := SimpleStruct{}
	wg := sync.WaitGroup{}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		wg.Add(2)
		go func() {
			for j := 0; j < M; j++ {
				structA.n += 1
			}
			wg.Done()
		}()
		go func() {
			for j := 0; j < M; j++ {
				structB.n += 1
			}
			wg.Done()
		}()
		wg.Wait()
	}
}

func BenchmarkStructurePadding(b *testing.B) {
	structA := PaddedStruct{}
	structB := SimpleStruct{}
	wg := sync.WaitGroup{}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		wg.Add(2)
		go func() {
			for j := 0; j < M; j++ {
				structA.n += 1
			}
			wg.Done()
		}()
		go func() {
			for j := 0; j < M; j++ {
				structB.n += 1
			}
			wg.Done()
		}()
		wg.Wait()
	}
}

```

测试结果

```shell
$ go test -gcflags "-N -l" -bench .
goos: linux
goarch: amd64
BenchmarkStructureFalseSharing-2   	     186	   6050044 ns/op
BenchmarkStructurePadding-2        	     417	   2924104 ns/op
PASS
```

可以看出，在amd64平台上测试，内存填充的优化是非常明显的，运行速度直接翻倍。但是这是一种空间换时间的做法，一般的场景很难需要这种机制的面向CPU执行效率的优化。

## 总结

虽然一些底层原理看起来与日常工作的联系并不紧密，但是理解底层硬件应该会让我们成为更好的开发人员。推而广之，对于底层原理的深入理解，会为我们应用真正调优、重构、设计等攻坚工作起到关键作用，下面摘录Medium原文的一段话：

机械同理心（Mechanical sympathy）是软件开发领域的一个重要概念，其源自三届世界冠军 F1赛车手 Jackie Stewart 的一句名言：

*You don’t have to be an engineer to be a racing driver, but you do have to have Mechanical Sympathy. （要想成为一名赛车手，你不必成为一名工程师，但你必须有机械同理心。）*

## 参考

- https://www.xwxwgo.com/post/2019/07/09/golang%E5%92%8Cfalse-sharing/
- https://teivah.medium.com/go-and-cpu-caches-af5d32cc5592
- https://zhuanlan.zhihu.com/p/343561193