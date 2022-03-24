---
title: "浅谈K8s集群联邦"
date: 2022-03-11T20:17:03+08:00
draft: true
typora-root-url: ../../static
---

## 大纲

- 我们想要什么效果：像使用单个K8s集群一样，在多个K8s集群部署应用；
- 单个集群中，我们是怎么做高可用的，node打az label，自行实现调度控制能力；
- Federation V1架构，如何实现，有什么问题
- Federation V2架构，做了哪些改进，有没有什么问题
- Karmada、公司自研的Pythia
- 如何定义跨集群的工作负载？如何分发工作负载到多个集群？

## 参考

- https://jimmysong.io/kubernetes-handbook/practice/federation.html
- https://feisky.gitbooks.io/kubernetes/content/components/federation.html
- 概念、Kubefed和karmada：https://draveness.me/kuberentes-federation/
- 概念、Kubefed和karmada：https://xinzhao.me/posts/kubernetes-multi-cluster-projects/
