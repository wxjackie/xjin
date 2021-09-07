---
title: "K8s拓扑分布约束实现Redis高可用调度的方案设计"
date: 2021-08-16T14:40:16+08:00
draft: false
---

# K8s拓扑分布约束实现Redis高可用调度的方案设计



## 一、背景

Redis Cluster在K8s上部署时，对于Pod的调度有一些特殊的高可用调度需求，默认的调度器无法满足需求，因此我们部门K8s团队先前自行开发了PaaS扩展调度器以支持一些中间件的高可用部署需求。

但是在我们的产品商业化过程中，部分客户环境不允许对K8s底层调度做改动，并且在实际部署中，PaaS扩展调度器的部署没有很好的观测性，容易遗漏这个依赖项。

在`K8s1.19`版本后，[Pod拓扑分布约束（Topology Spread Constraints）](https://kubernetes.io/docs/concepts/workloads/pods/pod-topology-spread-constraints/)已经成为稳定特性，因此需要调研是否能够剥离对扩展调度器的依赖，使用该原生特性设计调度策略来代替。

## 二、需求调研

首先需要明确Redis Cluster目前的高可用调度有哪些限制和语义，并分析是否能够通过拓扑分布约束特性配置达到相同语义的效果。需要提前说明的是，在我们的设计中，Redis分片用`StatefulSet`（简写为`Sts`）组织，一组主从属于同一`Sts`，一个Redis Cluster由多个`Sts`组成。

### 现有调度能力分析

目前Redis Cluster的调度要求如下

单AZ（可用域，Available Zone）调度要求：

- Redis集群同一分片的主从Pod不能同时存在于同一个**Node节点**
- 单个Node节点部署同一个集群的实例Pod数必须少于**1/3**

双AZ调度要求：

- Redis集群同一分片的主从Pod不能同时存在于同一个**可用域**
- 双AZ均分部署同一Redis集群的所有实例Pod
- 在满足上述前提下，单个AZ内尽可能分散部署实例Pod到不同的Node节点

三AZ及多AZ调度要求：

- Redis集群同一分片的主从Pod不能同时存在于同一个**可用域**
- 单个AZ部署同一Redis集群的实例Pod数必须少于集群Pod总数的**1/2**
- 在满足上述前提下，应避免不同机房部署同一Redis集群的Pod数量出现极端差异（特殊权重调度除外）

接下来分析上述调度要求目前分别是如何实现的：

- 主从Pod不能存在于同一Node节点或可用域：Operator在创建StatefulSet时，设置**Pod强制反亲和**实现，如果是单AZ，反亲和性的`TopologyKey`的值为`kubernetes.io/hostname`，多AZ时该值为`failure-domain.beta.kubernetes.io/zone`

- 单个Node节点、单个AZ部署Redis集群Pod数上限、必须调度的AZ：**PaaS扩展调度器**提供的语义实现，在Operator创建Redis集群时创建的调度Configmap中直接填写，例如

  ```yaml
  cluster-size: 18    // redis集群pod总数
  max-pod-on-node: 5  // 单个Node上该Redis集群Pod数上限
  max-pod-in-zone: 8  // 单个AZ内该Redis集群Pod数上限
  available-zones: cn-east-1a,cn-east-1b,cn-east-1c // 必须调度的AZ
  ```

### Pod拓扑分布约束能力分析

根据官方文档介绍，拓扑分布约束可以用来控制Pods在集群内故障域之间的分布，比如区域、节点和用户自定义的拓扑域等。该特性的核心字段是`maxSkew`，可以暂时理解为**最大偏差值**，实际意义根据`WhenUnsatisfiable`的取值不同而有差异：

- 当 `whenUnsatisfiable` 等于 "DoNotSchedule" 时，`maxSkew` 是目标拓扑域中匹配的Pod数与全局最小值之间可存在的差异，即强制要求拓扑域之间Pod数的差不能超过`maxSkew`。
- 当 `whenUnsatisfiable` 等于 "ScheduleAnyway" 时，调度器会更为偏向能够降低偏差值的拓扑域，即软性限制，即使两个拓扑域之间的Pod数的差超过`maxSkew`仍可以调度，只是调度会倾向于降低拓扑域间的偏差。

因此我们可以根据Redis集群Pod总数和AZ信息，根据该特性设置Pod在Node节点或AZ的分布均匀程度，实现原本由扩展调度器语义提供的相同功能。

## 三、设计

### 调度配置设计

下面介绍对于原有扩展调度器功能的替代方案，初始化创建Redis集群的配置逻辑如下

- 单个Node节点、单个AZ部署Redis集群Pod数上限：同一Redis集群Node节点维度

  ```yaml
  topologyKey: kubernetes.io/hostname
  maxSkew: Pod总数/3 // 如果Pod总数能够被3整除，则再减1
  whenUnsatisfiable: DoNotSchedulegit 
  ```

   同理，如果是多AZ环境在保留上述Node偏差值约束的条件下，再加一条

  ```yaml
  topologyKey: failure-domain.beta.kubernetes.io/zone
  maxSkew: Pod总数/2 // 如果Pod总数能够被2整除，则再减1
  whenUnsatisfiable: DoNotSchedule
  ```

- 必须调度的AZ：直接配置Pod的节点亲和性实现，在多AZ环境下，由于有AZ间`maxSkew`的约束，不会出现有某个AZ调度不到的问题。

- Redis集群同一分片的主从Pod不能同时位于同一Node或Zone：保持现有方案，仍然采用设置同一`StatefulSet`内Pod强制反亲和实现。

- 除了上述硬性约束外，同集群Node维度再额外添加偏好约束，使Pod分布在Node尽可能的均匀。（如果是多AZ再加上Zone维度）

  ```yaml
  topologyKey: kubernetes.io/hostname
  maxSkew: 1
  whenUnsatisfiable: ScheduleAnyway
  ```

水平扩缩容时，分片数变化，Pod总数也会改变，因此水平扩缩容的配置逻辑为：

- 在检查到集群声明的分片数与Sts个数不同时，则重新计算限制规则，并更新到所有`Sts`中
- 如果是水平扩容（新增Sts），则新创建出的Pod已经按照新的集群大小配置`maxSkew`，存量的Pod配置不变，但所属的Sts配置已改变，能够保证重建、垂直升级功能的正常运行。

### 调度推演

接下来推演典型的三分片Redis Cluster使用该方案的调度流程，假设环境为3个AZ，每个AZ两个Node，调度推演流程如图所示（生成的Pod中的调度配置较长，放在文档尾部**补充参考1**中）：

![new-pod-schedule1](/img/pod-topo/pod-schedule1.jpg)

Redis Operator创建出`StatefulSet`后，默认每个`Sts`副本数为2，前缀相同的`Pod`属于同一`Sts`，如`Pod0-0和Pod0-1`。每个`Sts`的`0号Pod`会先被调度，下面对每一步做具体的分析：

1. 首先3个`Sts`的0号Pod会最先被调度，由于均匀分布策略，可以假定`Pod0-0、Pod1-0、Pod2-0`分别调度到`Node1、Node4、Node6`上，如上图。
2. 接下来推演每个Sts的第二个Pod的调度逻辑，由于AZ维度的`maxSkew = 6/2 -1 = 2`，Node维度的`maxSkew = 6/3 - 1 = 1`，`Pod0-1`可能调度到除`Node1`和`Node2`之外任何一个节点（调度到`Node1`则Node维度的最大偏差值为2，大于`maxSkew`，所以不可能调度到`Node1`），这里先假设调度到`ZoneB`的`Node3`。
3. `Pod1-1`只能被调度到`Node2`和`Node5`（因强制反亲和不能调度到Zone2，调度到已有Pod的其他Zone的Node回使得Node维度最大偏差值超过限制）假定调度到Node5。同理分析可知，此时`Pod2-1`只能调度到`Node2`（根据现有要求，这里可能存在调度死锁问题，在文档尾部**补充参考2**中描述。）

单AZ的场景更为简单，只要Node数量足够（>= 6）即可完成调度，不再画图推演。

## 四、功能验证

测试环境为Kind搭建的`K8s1.19`集群，1个master，6个node均分到3个AZ，针对不同AZ数做基础的场景验证。

单AZ

- 3分片集群创建、水平扩容到5分片、垂直升级、重建：正常
- 6分片集群创建、水平扩容到10分片，再缩回5分片、垂直升级、重建：正常

双AZ（暂不支持垂直升级）

- 3分片集群创建、水平扩容到5分片、重建：正常
- 6分片集群创建、水平扩容到10分片，再缩回5分片、重建：正常

三AZ

- 3分片集群创建、水平扩容到5分片、垂直升级、重建：正常
- 6分片集群创建、水平扩容到10分片，再缩回5分片、垂直升级、重建：正常

## 五、结论

使用Pod拓扑分布约束功能，基本可以代替初版扩展调度器提供的能力，建议后期使用，以剥离对扩展调度器的依赖，其他中间件也可以使用此特性实现Pod在Node、Zone或其他自定义拓扑域均匀分布的效果。但是此方案也会引入一些需要考虑和优化的问题。

- 在现有调度约束下，三分片Redis集群使用该机制可能存在调度死锁问题，需要评估是否可以放宽些限制，针对**3分片集群**这一特例把先前的**小于1/3和1/2**改为**不大于**。（参考文档末尾的**补充参考**部分）
- 存在一些极端场景可能出现不满足我们先前的"1/3"和"1/2"Pod总数约束的情况，比如单个Node上最少Pod数大于0，缩容等，因此需要考虑对于调度分布添加检查和事件报警。
- 现有调度要求必须要有最少6个Node可调度，否则无法调度成功；使用Pod拓扑分布约束的方案，Node少于6个也可以调度成功，但Node数少于6个时无法保证`maxPodOnNode < 1/3`的要求。

## 六、补充参考

1. 推演调度场景中生成的Pod调度配置

   ```yaml
   spec:
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
           - matchExpressions:
             - key: failure-domain.beta.kubernetes.io/zone
               operator: In
               values:
               - zoneA
               - zoneB
               - zoneC
       podAntiAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
         - labelSelector:
             matchLabels:
               cloud.netease.com.ncr/ncrnode: rediscluster-3az-6379-2
               cloud.netease.com.ncr/type: endpoints
               cloud.netease.com/app: ncr
               cloud.netease.com/cluster-name: rediscluster-3az-6379
           topologyKey: failure-domain.beta.kubernetes.io/zone
     topologySpreadConstraints:
     - labelSelector:
         matchLabels:
           cloud.netease.com.ncr/type: endpoints
           cloud.netease.com/app: ncr
           cloud.netease.com/cluster-name: rediscluster-3az-6379
       maxSkew: 1
       topologyKey: kubernetes.io/hostname
       whenUnsatisfiable: DoNotSchedule
     - labelSelector:
         matchLabels:
           cloud.netease.com.ncr/type: endpoints
           cloud.netease.com/app: ncr
           cloud.netease.com/cluster-name: rediscluster-3az-6379
       maxSkew: 2
       topologyKey: failure-domain.beta.kubernetes.io/zone
       whenUnsatisfiable: DoNotSchedule
   ```

2. 模拟调度死锁：假设`Pod0-1`调度到了`Node3`后，`Pod1-1`调度到了`Node-2`，这时`Pod2-1`将无法调度，因为根据同`Sts`内Zone维度的强制反亲和，它不能与`Pod2-0`调度到相同的Zone，即无法调度到`Node5`；根据同集群Node节点维度`maxSkew = 1`，它无法调度到除`Node5`外其他节点，如图所示：

   ![new-pod-schedule2](/img/pod-topo/pod-schedule2.jpg)

   这种情况现有逻辑根据现有要求无法避免，需要评估是否可以放宽些限制，即将“单个Node上Pod数少于总数1/3”和“单个Zone内的Pod数少于总数1/2”的“少于”都改为“不超过”，即可避免调度死锁，**目前评估只有多AZ、3分片时需要放松限制，即将同集群Node维度的计算结果`maxSkew = 1 `改为2**