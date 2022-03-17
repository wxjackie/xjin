---
title: "多版本并发控制MVCC机制详解"
date: 2020-10-19T09:38:03+08:00
draft: true
typora-root-url: ../../static
---

> MVCC，全称Multi-Version Concurrency Control，即多版本并发控制，常见于数据库管理系统中，对数据库的并发访问做控制，比如并发访问数据库时，对正在事务内处理的数据做多版本的管理，用来避免由于写操作的堵塞，而引发读操作失败的问题。