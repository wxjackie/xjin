---
title: "使用ChaosBlade模拟异地环境测试"
date: 2021-09-08T09:58:44+08:00
draft: true
typora-root-url: ../../static
---

https://g.hz.netease.com/ncr-3.0/docs/-/blob/master/%E6%B5%8B%E8%AF%95%E6%96%87%E6%A1%A3/Redis%E4%B8%BB%E4%BB%8E%E5%BC%82%E5%9C%B0%E5%9C%BA%E6%99%AF%E6%A8%A1%E6%8B%9F%E6%B5%8B%E8%AF%95%E6%8A%A5%E5%91%8A.md

## 参考

- 混沌工程介绍和对比：https://www.naah69.com/post/2020-01-06-chaos-mesh/
- 模拟Node宕机，JVM问题仍使用Chaosblade。
- ChaosBlade并不是专门面向K8s的，起初它是一个管理各种故障注入二进制文件的框架，即各个二进制脚本负责具体的故障注入，ChaosBlade负责调用以实现对单个物理节点的故障注入。Chaosblade是个更普适的工具，并不是特定为了K8s设计的，它在物理机、JVM应用的功能点支持很多。后来为了弥补在K8s平台的不足，补充了Chaosblade Operator项目，整体模型还是沿用Chaosblade，所以一些设计上的注入定义方式可能不是很符合K8s的模式。
