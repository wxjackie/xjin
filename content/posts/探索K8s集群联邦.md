---
title: "探索Kubernetes集群联邦方案"
date: 2022-03-07T20:17:03+08:00
draft: false
tags: ["K8s", "高可用"]
categories: ["K8s"]
summary: 分析K8s集群联邦机制的需求以及社区主流的解决方案。
typora-root-url: ../../static
---

> Kubernetes 从 1.8 版本起就声称单集群最多可支持5000个节点和15万个Pod，目前在我们实际的线上环境还没有达到如此大的节点规模，应该很少有公司会选择维护一个如此巨大的K8s集群。
>
> 在我们实际线上环境约1000个节点的K8s集群使用中，我们已经碰到了一些集群整体问题，比如API Server卡顿、单Node宕机时无关告警众多等等；基于节点规模巨大、多云环境、故障隔离、集群维度高可用等多重问题考虑，业务同时使用多个K8s的需求呼之欲出，最近我们也在考虑如何将中间件容器化做到跨K8s集群高可用。如何能够统一管理多个K8s集群，让上层用户无感知地将多K8s集群视为一个整体K8s集群去使用，这就引出了集群联邦（Cluster Federation）的概念。

## 单集群的现状

我个人目前接触到使用较多K8s节点的集群（约1000个K8s节点），出现过或仍旧存在以下问题：

- 由于过多不合理使用API Server的work load，导致API Server卡顿，对其他业务造成影响。
- 因为调度层面隔离较混乱（业务可能会自己配置NodeSelector、Affinity等），每个K8s节点宕机都需要所有运维人员关注。
- 单K8s集群纳管**同城多机房**的节点，在节点上打AZ Label作为标识，每个需要多AZ高可用的业务都需要根据AZ Label自行设计调度逻辑。如下图所示，一个中间件的Operator，需要在实现逻辑中设计Pod在不同AZ的高可用调度。

![image-20220329191909410](/img/discuss-k8s-federation/single-cluster.png)

简单分析下这些问题：单个K8s集群的基础设置是有可能被业务影响导致不稳定进而影响其他业务、每个业务的高可用调度的实现水平、验证完备程度也是不同的。可以总结为**故障隔离较差、跨机房高可用缺乏硬性限制**。

## 设计理念与目标

考虑到集群联邦的通用性和故障隔离性，在设计时要尽量保证联邦控制面逻辑简洁，业务逻辑仍下放到成员（Member）集群，由各成员集群处理。因此，集群联邦最基础的功能，就是**跨集群资源转播**，比如我们声明一个Deployment，联邦需要帮我们把这个Deployment传播到成员集群，在成员集群中按照一定规则各自创建Deployment。

关于集群联邦的目标，或者说能用它做到什么事情，社区已经有很多阐述了，大致如下：

- 高可用：实现K8s集群维度的高可用，最大限度地减少了集群故障带来的影响。
- 故障隔离：多个小集群本身也比一个大集群更利于故障隔离，节点故障会被限制在单个成员K8s集群内，PE关注粒度更为精准。
- 避免厂商锁定：提供跨集群应用迁移的功能，可以同时拥有并使用多个云服务商的多个K8s集群（需要关注地域问题和网络情况）
- 可伸缩性：K8s官方声明单集群最多5000节点，如需更大规模可拆分集群做到水平伸缩，除了公有云服务商，应该很少会有这种需求。

除此之外，还有一个比较重要的诉求：允许业务像使用单个K8s集群使用集群联邦。为什么单独把这点列出来呢？因为我们在实践过程中发现这个诉求有些理想化：对于无状态应用，还是可以做到尽量透明的；但是对于有状态应用，比如Redis Cluster等中间件则很难实现不感知多集群。

集群联邦在K8s社区目前还算是一个比较高级的课题，SIGs和一些云厂商都在探索各自的集群联邦多云管理机制，下面介绍几种主流的集群联邦框架。

## Federation V1

Federation V1早期由K8s社区提出，由于设计上的问题，最终在`K8s 1.11`左右彻底弃用。下面根据架构图对Federation V1做简要的介绍。

![federation-v1](/img/discuss-k8s-federation/fedev1.png)

主要组件：

- Federation API Server：类似API Server，对外提供统一的资源管理入口，但只允许使用 [Adapter](https://github.com/kubernetes-retired/federation/tree/master/pkg/federatedtypes) 拓展支持的 K8s 资源。
- Controller Manager：提供多个集群间资源调度及状态同步
- ETCD：储存 Federation 的资源和元信息

大致工作流程：

- 声明一个Deployment（GroupVersion仍然是K8s原生的，但是需要确保Federation已经适配支持该GVK），将联邦的配置信息（各个成员集群分配的副本）写到Annotations中，然后将该Deployment提交到Federation API Server。
- Federation Controller Manager根据资源对象的Annotations中的配置，向各个子集群发起请求创建Deployment资源。并将状态回写到Federation层的Deployment资源对象中。

问题：

- 比较明显的问题是，要对每一个新增资源类型创建Adapter适配。
- 联邦控制面使用的资源API与K8s资源对象原生API一致，只写入Annotations又会导致放置策略、覆写策略不灵活，并且Federation没有自己的GA路径，需要不停地适配K8s资源对象API。

## KubeFed（Federation V2）

基于V1版本的问题和经验，社区推出了Federation V2。现在一般说到KubeFed，所指的默认就是Federation V2。它使用了CRD的机制，通过定义多种CR（自定义资源）实现。V2移除了V1中Federation独立的API Server和ETCD，使其可以部署在任意一个K8s集群中，即联邦控制面所在的集群也可以作为一个子集群加入联邦。

![img](/img/discuss-k8s-federation/fede-v2.png)

KubeFed在V1基础上移除了Federation API Server和ETCD，通过定义几中CRD增强了Federation Controller Manager的能力，这里CRD更像是核心组件，这里介绍下他们的能力（表格来源：https://jimmysong.io/kubernetes-handbook/practice/federation.html）。

| API Group                      | 用途                                                  |
| ------------------------------ | ----------------------------------------------------- |
| core.kubefed.k8s.io            | 集群组态、联邦资源组态、KubeFed Controller 设定档等。 |
| types.kubefed.k8s.io           | 被联邦的 Kubernetes API 资源。                        |
| scheduling.kubefed.k8s.io      | 副本编排策略。                                        |
| multiclusterdns.kubefed.k8s.io | 跨集群服务发现设定。                                  |

这四种CRD可以被分为四种概念，下面为大致介绍：

- Cluster Configuration：定义哪些K8s集群要被联邦。可通过`kubefedctl join/unjoin`来加入/删除集群，当成功加入时，会建立一个 KubeFedCluster 组件来储存集群相关信息，如 API Endpoint、CA Bundle 等。这些信息会被用在 KubeFed Controller 存取不同K8s集群，会区分Host和Member集群，Host是提供KubeFed API和控制平面的集群，它本身也可作为Member加入联邦。整体如下图所示：

  ![KubeFed-Cluster-Configuration](/img/discuss-k8s-federation/sync-controller.png)

- Type Configuration：定义了哪些 K8s资源要被用于联邦管理。比如说想将ConfigMap通过联邦建立在不同集群上时，就必须先Host集群中，通过CRD建立新资源 FederatedConfigMap，接着再建立名称为 configmaps 的 FederatedTypeConfig资源，然后描述ConfigMap要被 FederatedConfigMap 所管理，这样 KubeFed Controllers才能知道如何建立 Federated 资源。一个FederatedTypeConfig的YAML示例：

  ```yaml
  apiVersion: core.kubefed.k8s.io/v1beta1
  kind: FederatedTypeConfig
  metadata:
    name: configmaps
    namespace: kube-federation-system
  spec:
    federatedType:
      group: types.kubefed.k8s.io
      kind: FederatedConfigMap
      pluralName: federatedconfigmaps
      scope: Namespaced
      version: v1beta1
    propagation: Enabled
    targetType:
      kind: ConfigMap
      pluralName: configmaps
      scope: Namespaced
      version: v1
  ```

  一个Federation资源示例：

  ```yaml
  apiVersion: types.kubefed.k8s.io/v1beta1
  kind: FederatedDeployment
  metadata:
    name: test-deployment
    namespace: test-namespace
  spec:
    template: # 定义 Deployment 的所有內容，可理解成 Deployment 与 Pod 之间的关联。
      metadata:
        labels:
          app: nginx
      spec:
        ...
    placement:  # 定义Federated资源要分散到哪些集群上
      clusters:
      - name: cluster2
      - name: cluster1
    overrides:   # 定义修改指定集群的 Federated 资源中的 spec.template 内容，比如副本数，拉取镜像秘钥等特定集群的信息。
    - clusterName: cluster2
      clusterOverrides:
      - path: spec.replicas
        value: 5
  ```

- Scheduling：KubeFed可以使用`ReplicaSchedulingPreference`（RSP）机制，实现权重分布，最小/最大限制等语义，这块在使用上比较好理解，示例YAML如下：

  ```yaml
  apiVersion: scheduling.kubefed.k8s.io/v1alpha1
  kind: ReplicaSchedulingPreference
  metadata:
    name: test-deployment
    namespace: test-ns
  spec:
    targetKind: FederatedDeployment
    totalReplicas: 15 
    clusters: 
      "*":
        weight: 2
        maxReplicas: 12
      ap-northeast:
        minReplicas: 1
        maxReplicas: 3
        weight: 1
  ```

- Multi-Cluster DNS：实际使用中跨集群的服务发现功能非常复杂，社区中目前已经有很多第三方的工具可以提供基于 DNS 的联邦 Ingress 资源，一般不需要KubeFed在这里做支持。

问题：

- 虽然解决了V1的GroupVersion耦合问题，但它为所有原生资源创建了对应的联邦资源（Federated Resource），新增一种资源就需要新增一种联邦资源映射。
- RSP机制只能支持K8s原生资源的调度限制，目前支持Deployment和ReplicaSet，对于广泛使用CRD的Operator服务不够友好。

## Karmada

Karmada是华为开源的多集群管理框架，它是KubeFed的一个延续，集成了Federation V1和V2的一些基本概念，它也是目前社区中比较活跃和成熟的集群联邦框架。下面为Karmada架构图：

![karmada-arch](/img/discuss-k8s-federation/karmada-arch.png)

主要组件：

- Karmada API Server：一个独立的API Server，绑定了一个单独的ETCD用来存储联邦资源。
- Karmada Controller Manager：多个Karmada Controller集合，只处理Karmada联邦资源，监听Karmada API Server中的资源对象并与子集群API Server通信。
  - Cluster Controller：将子集群加入Karmada联邦，通过Cluster资源管理子集群的生命周期。
  - Policy Controller：监视PropagationPolicy资源，会选择与 resourceSelector 匹配的一组资源，并为每个资源对象创建 ResourceBinding。
  - Binding Controller：监视ResourceBinding资源，针对各个子集群创建对应的资源对象的Work资源。
  - Execution Controller：监视Work资源，将Work资源包含的资源分配给各个子集群。
- Karmada Scheduler：提供可扩展的，跨集群级别的调度策略。

Karmada工作流程图如下，配合上面对于各个Karmada Controller的解释，基本可以理解这张图的处理流程：

![Karmada-process](/img/discuss-k8s-federation/karmada-process.png)

相较于KubeFed，Karmada保留了K8s原生资源对象，无需像KubeFed一样定义`FederatedXXX`等CRD，而是引入了PropagationPolicy 和 OverridePolicy实现资源传播和字段覆写。

站在Operator开发者的角度，我认为Karmada这种方式能够更易于维护，因为Operator本身也要引入CRD，创建独立的 PropagationPolicy 和 OverridePolicy 可以简化引入新资源需要的步骤，避免引入更多的FederatedCRD，只是缺少了FederatedCRD来收集汇总多集群的资源状态，但这个完全可以通过其他方式实现，比如在控制平面新增一个简单的Controller（听起来复杂，但实际情况下往往是必要的。）

## 总结

## 参考

- [集群联邦（Cluster Federation）](https://jimmysong.io/kubernetes-handbook/practice/federation.html)
- [Federation V1](https://feisky.gitbooks.io/kubernetes/content/components/federation.html)
- [Karmada Repo](https://github.com/karmada-io/karmada)
- [Kubernetes、集群联邦和资源分发](https://draveness.me/kuberentes-federation/)
- [多集群项目使用介绍](https://xinzhao.me/posts/kubernetes-multi-cluster-projects/#karmada)
