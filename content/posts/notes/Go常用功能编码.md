---
title: "Golang常用功能编码示例"
date: 2021-11-12T10:42:03+08:00
draft: true
typora-root-url: ../../../static
---

## Wait工具包

链接：https://icebergu.com/archives/client-go-wait

`wait` 包提供了通过轮询或者监听一个条件的修改(关闭channel, ctx.Done,...)来执行指定函数的工具函数. 这些函数可以分为四大类。

- Until 类: 根据 channel 的关闭或者 context Done 的信号来结束对指定函数的轮询操作
- Poll 类：不只是会根据 channel 或者 context 来决定结束轮询，还会判断轮询函数的返回值来决定是否结束
- Wait 类: 会根据 WaitFor 函数返回的 channel 来触发函数执行
- Backoff 类：会根据 Backoff 返回的时间间隔来循环触发函数的执行





