---
title: "基于K8s的Redis云原生实践综述"
date: 2021-01-27T17:53:16+08:00
draft: false
tags: ["Redis", "云原生", "K8s"]
categories: ["中间件", "K8s"]
---
# 基于K8s的Redis云原生实践综述

> 随着云原生时代的到来和Kubernetes（简称K8s）的日渐成熟，越来越多的互联网团队开始将Kubernetes作为新的重要基础设施，一些云计算厂商也将其视作云服务及应用交付的新底座。在大家的普遍认知里，Kubernetes是一个容器编排系统，擅长无状态的应用部署管理，在微服务领域起到了重要作用。由于容器对外部基础环境的不感知和状态易失的特性，与有状态应用的管理似乎有天然的矛盾。Operator就是“有状态应用容器化”的一个优雅的解决方案，本文将介绍网易轻舟中间件基于Operator的Redis容器化实践。

## Redis、Kubernetes预备知识
![](/img/redis+k8s.jpg)

Redis是基于Key-Value的缓存数据库，具有高性能、数据结构丰富、原生的高可用和分布式支持等特点，是目前业界使用最广泛的缓存中间件之一。从Redis 3.0版本开始，推出了**Redis Cluster**这一原生的、集群自治的分布式解决方案，支持**在线水平扩缩容**和**故障自动转移**，帮助我们突破了单机内存、并发、流量的瓶颈。


Kubernetes是Google开源的容器编排管理系统，是Google多年大规模容器管理技术Borg的开源版本，主要功能有：
- 基于容器的应用部署、维护和滚动升级
- 负载均衡和服务发现
- 跨机器和跨地区的集群调度
- 自动伸缩
- 无状态服务和有状态服务
- 插件机制保证扩展性

下面简要介绍几种K8s中的几种常用的**K8s核心组件**和**资源对象**，便于下文的理解。

首先是几个本文中要多次提及的K8s基础组件：
- **Controller Manager**：
    - K8s中的大多资源对象都有对应的**控制器**（Controller），他们合在一起组成了kube-controller-manager。
    - 在机器人技术和自动化领域，控制回路（Control Loop）是一个非终止回路，用于调节系统状态。生活中最典型的控制回路的例子：空调。比如我们设置了温度，相当于告诉了空调我们的期望状态，房间的实际温度是当前状态，通过对设备的各种控制，空调使温度接近于我们的期望。控制器通过控制回路将K8s内的资源调整为声明式API对象期望的状态。
- **ETCD**：
    - 是CoreOS基于Raft开发的分布式Key-Value存储，保存了整个K8s集群的状态，可用于服务发现和一致性保证（比如选主）。
    - Etcd被部署为一个集群，几个节点的通信由Raft算法处理。在生产环境中，集群包含奇数个节点，并且至少需要三个，通常部署在K8s Master上。
- **API Server**：
    - 提供了资源操作的唯一入口，并提供认证、授权、访问控制、API 注册和发现等机制。
    - 它是其他模块之间的数据交互和通信的枢纽(其他模块通过API Server查询或修改数据，只有API Server才直接操作ETCD)。
- **Kubelet**：
    - 负责维护容器的生命周期，同时也负责 持久卷(CVI)和网络(CNI)的 管理。
    - 每个Node节点上都运行一个Kubelet服务进程，默认监听10250端口，接收并执行Master发来的指令，管理Pod及Pod中的容器。

下面介绍一些常用的资源对象：
- **Pod**：Pod是一组紧密关联的容器集合，是Kubernetes调度的基本单位。多个容器在一个Pod中共享网络和文件系统，Pod和容器的概念和关系有些类似于主机和进程。
- **Node**：Node是Pod真正运行的主机，可以是物理机，也可以是虚拟机，Node上需要运行着container runtime（比如Docker）、kubelet和kube-proxy服务。
- **StatefulSet**：为了解决有状态服务的问题(对应 Deployments 和 ReplicaSets 是为无状 态服务而设计)，通过稳定的存储、网络标识、Pod编序等功能来支持有状态应用。
- **Deployment**：是一种更高阶资源，用千部署应用程序并以声明的方式升级应用，替代和ReplicationController来更方便的管理应用。
- **ConfigMap**：用于保存配置数据的键值对，可以用来保存单个属性，也可以用来保存配置 文件，在K8s的使用中我们通过ConfigMap实现应用和配置分离。
- **Service**：K8s中用于容器的服务发现和负载均衡的资源对象，分为ClusterIP（生成K8s集群内的虚拟IP作为入口）、NodePort（在ClusterIP基础上在每台机器上绑定一个端口暴露，使得能通过机器IP加该端口访问）、LoadBalancer等。

整体K8s架构如下图所示：
![architecture](/img/redis-on-k8s/architecture.png)


## 从传统主机到Kubernetes，从无状态到有状态

在介绍Kubernetes Operator之前，我们先来分析一下传统的有状态应用部署方式所存在的问题。

以前当开发者想要在物理机或云主机上部署Redis、Kafka等有状态应用，并且对于这些应用的集群有一定程度的运维控制能力时，往往需要编写一套复杂的管理脚本、或者开发一个拥有诸多依赖的Web管控服务。站在普通使用者的角度，他们不得不为此学习与本身业务开发无关的运维知识。

如果是以脚本和运维文档的方式沉淀，缺乏标准化的管理会使得运维的学习成本和使用门槛随着使用过程中的修改而急速升高；而使用管控服务，则需要引入更多的底层依赖去满足管控服务与主机侧的交互的虚拟化和管理设施，云计算厂商许多都使用了OpenStack作为基础设施管理平台，严格来说，OpenStack和Kubernetes不属于同一层面的框架，前者更多是属于IaaS层，更多是面向基础设施做虚拟化，Kubernetes则更偏向上层的应用容器化编排管理。在实际使用中，我们认为自行组织OpenStack对于小规模用户私有云的使用需求，有些过于沉重了。

于是我们将目光投向**对基础设施关注更少、自动化程度更高**的Kubernetes。我们都知道Kubernetes在无状态应用部署管理，尤其是微服务领域，已经大放异彩。例如管理一个无状态的Web服务，我们可以使用K8s的Deployment部署多副本并且进行弹性伸缩和滚动升级，然后使用Sevice进行负载均衡，依靠K8s原生的资源对象基本上可以覆盖无状态服务的整个生命周期管理。

然而，对于Redis、Kafka这类“有状态”的应用，K8s似乎并没有准备好接纳它们。首先我们总结一下有状态应用的两个重要的特点：

1. 对**外部存储或网络**有依赖，比如Kafka、TiDB每个副本都需要稳定的存储卷。
2. 实例之间有**拓扑关系**，比如Redis Cluster中存在主从关系和数据路由分布。

这就给K8s带来了挑战，如果仍使用Deployment和ReplicaSet这些对象，Pod在故障时，对于Redis Cluster无法只是简单地重启Pod就能恢复到健康的集群状态，同理Kafka的Pod也会“忘记”自己所使用的存储卷。

K8s推出了StatefulSet这一资源对象旨在解决有状态应用的管理问题，允许在StatefulSet中配置持久卷（PersistentVolume，简称PV）、稳定的网络标识，对其内部的Pod进行编号排序等。但是对于Redis Cluster这种拥有自治能力的集群，StatefulSet也显得不够灵活而且会与其自治能力有冲突。

## Redis也想要声明式管理

K8s的自动化哲学有两个核心概念：**声明式API和控制器（controller）模式**。比如我们声明一个三副本的Deployment提交给API Server，K8s中负责Deployment的controller就会监视（Watch）它的变化，发现该Deployment的Pod数为零，对其进行调谐（Reconcile），创建三个Pod，使它达到我们所声明的状态。

这引发了我们的思考：是否可以将Redis视作像Deployment一样的资源对象进行声明式的管理，同样拥有一个controller对它进行调谐呢？

这是一个合理且强烈的需求，即资源对象和controller都是由我们自定义，由我们自行编写资源的生命周期和拓扑关系的管理。于是Operator应运而生，可以将其简单的理解为：

```
Operator = CRD（Custom Resources Definition）+ Custom Controller
```

如今Operator在社区中已经非常火热，但我们在最初设计做调研时，发现社区的Redis Operator实现上虽简洁，但运维能力和我们作为云计算服务商所强调的风险掌控、兜底能力不足，于是我们NCR（Netease Cloud Redis）团队借鉴社区的经验开发了自己的Redis Operator，下面针对Redis Cluster模式的管理进行解读，总体架构如下图所示：

![operator-structure](/img/redis-on-k8s/operator-structure.jpg)

Redis Operator自身采用Deployment进行三副本部署，通过ETCD选主。Redis Cluster每个分片内的两个Pod上的Redis实例为一主一从，每个分片由一个StatefulSet管理；Pod的调度策略由K8s原生调度器和网易轻舟K8s提供的扩展调度器共同保障，对于StatefulSet、Pod等原生资源对象的管理仍使用原生API。

开始使用Redis Operator，首先我们需要提交一个属于Redis的资源定义（CRD），定义一个Redis集群所必要的规格描述（Specification），之后用户便可以提交CR（通常是以yaml文件的形式），并在CR的Spec中填写自己需要的规格信息后提交，剩下的工作，无论是**创建、弹性扩缩容、故障处理**，统统交给Redis Operator自动化调谐。下面是一个典型的CR实例：

```yaml
apiVersion: ncr.netease.com/v1alpha1
kind: NcrCluster	# 资源类型，在CRD中所定义
metadata:
  name: cluster-redis # CR名称
  namespace: ns				# CR所在的namespace
spec:
  availableZones:			# 可用区列表，支持单、多AZ
  - azName: az1
  configFile: ncr-cluster-configmap	# 默认的配置参数模板
  master: 3													# 分片数
  port: 6379												# 端口号
  version: redis:4.0.14							# Redis引擎版本
  resourceReqs:											# K8s标准资源规格描述
    requests:
      cpu: 1
      memory: 2Gi
    limits:
      cpu: 2
      memory: 4Gi
```

下面简要分析一个Redis Cluster的CR提交后的Operator主干工作流程：
1. Redis Cluster对应的Informer感知到CR的Add事件。
2. 对该CR的Spec进行校验，包括是否符合CRD中的校验规则以及Operator内置的校验逻辑。
3. 校验通过后，开始对该集群进行调谐（Reconcile），感知到CR的Status为空判断为新创建的Redis集群，进入创建流程。
4. 根据默认Redis配置模板生成引擎配置，生成一个该CR专用的引擎参数ConfigMap和一个调度ConfigMap，我们通过在调度层面的策略针对单、多机房做了高可用保障。
5. 创建NodePortService用于服务发现访问。
6. 为Redis Cluster每个分片创建StatefulSet并将CR中的资源规格传入，作为最终Pod的资源规格。
7. 待所有StatefulSet的Pod启动成功后，在每个Pod上运行Redis Server进程，并进行Redis Cluster的组建流程，如cluster meet和add slots等。
8. 完成后将CR的状态更新为Online，表明已完成创建，之后根据Infomer的机制，每30s会收到到Update事件，轮询式的进行Reconcile。

## Operator，拥有运维知识的专家

下图为Redis Operator的工作流程图，实际上Operator就是我们对Kubernetes API进行了扩展和自定义，整体的工作流程与原生内置的controller是一致的.
![Operator workflow](/img/redis-on-k8s/operator-workflow.jpg)

那么这种设计理念有什么好处呢？借用Operator Framework官网的一句话：

> The goal of an Operator is to put operational knowledge into software. 

即“Operator旨在将领域性的运维知识编写成代码融入其中”。这个理念会影响我们对Redis Operator的设计与开发。

列举一个场景说明，假如我们有在物理机上手工部署的Redis Cluster集群其中一个Master实例故障，并发生了Failover，此时该实例处于宕机状态，如果是人工恢复我们需要做的工作大致为：

1. 判断分片是否正常工作，即分片内另一个节点是否已经接替成为Master。
2. 准备将该实例作为Slave重启，做操作的预检查。比如Master的流量很高时，需要更大的复制缓冲区，需要检查Master的内存空闲情况，或者CPU占用超过一定阈值时不做操作，待流量低峰时进行重启和复制。
3. 重启实例，加入集群，并且复制指定Master实例，持续检查复制状态直到稳定。

上述每一步操作判断都涵盖了我们的Redis运维知识，根绝Operator的理念，我们应该将这些知识编写成代码。通过明确的指标去做判断，比如判断QPS低于5000、CPU使用低于60%，Master内存空闲大于2GB时允许自动重建修复，将故障自动恢复或调谐的能力交给Operator，极大地提高了自动化运维的程度，可以称Redis Operator为运行在Kubernetes上，拥有Redis运维知识和判断能力的“运维专家”。

## 优势总结和落地情况

最后总结一下Redis采用Operator方案做容器化的优势：

- 降低运维成本，支持对更大规模Redis集群的管理。
- 容器部署相对于传统主机部署在资源方面更加有弹性。
- 调度控制实现反亲和更加简单，借助K8s本身的调度器和Taint、Toleration等机制。
- 基于K8s的方案对基础设施耦合低，用户可以根据实际规模选择用物理机或云服务器部署。

目前网易轻舟自研的Redis Operator提供的功能有：

- 两种模式的Redis：Redis Cluster和Redis主从版（Sentinel管理）
- 单、多AZ高可用部署支持
- 集群创建、删除
- 集群在线水平、垂直扩缩容，热配置更新
- 实例重启、重建的运维功能
- Prometheus监控和报警功能
- RDB数据冷备与恢复

时至今日，Redis Operator已经在网易云音乐线上环境自2019年底稳定运行至今，网易传媒、网易严选也在逐渐扩大线上的使用规模，得益于自动化运维的高效、资源成本的优化，相信Operator将成为成规模的有状态分布式应用容器化的标准。