---
title: "ChaosMesh混沌工程实践"
date: 2022-02-21T20:17:03+08:00
draft: true
typora-root-url: ../../static
---

## 参考

- 混沌工程介绍和对比：https://www.naah69.com/post/2020-01-06-chaos-mesh/
- 模拟Node宕机，JVM问题仍使用Chaosblade。
- ChaosBlade并不是专门面向K8s的，起初它是一个管理各种故障注入二进制文件的框架，即各个二进制脚本负责具体的故障注入，ChaosBlade负责调用以实现对单个物理节点的故障注入。Chaosblade是个更普适的工具，并不是特定为了K8s设计的，它在物理机、JVM应用的功能点支持很多。后来为了弥补在K8s平台的不足，补充了Chaosblade Operator项目，整体模型还是沿用Chaosblade，所以一些设计上的注入定义方式可能不是很符合K8s的模式。