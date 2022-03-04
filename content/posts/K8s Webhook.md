---
title: "K8s Admission Webhook深入实践"
date: 2021-11-12T10:42:03+08:00
draft: false
typora-root-url: ../../static
---

> 在一个管理容器化资源的平台开发过程中，我们有时会发现这种需求：一个资源对象在发生创建、更新、删除的API请求时，我们需要做一些附加的操作，比如给一个资源对象加Label，调整规格等；资源对象创建或删除时，要做一定的校验，对创建或删除的动作做一定的限制。
>
> 这就引出了K8s的一个功能，Admission Webhook，顾名思义，它是一种捕获特定请求并对其进行处理的回调机制，可以实现对K8s API Server的请求进行拦截和预处理的功能。

## 准入控制器介绍

根据官方文档的描述，准入控制器是一段代码。它会在请求通过认证和授权后，对象被持久化之前拦截到达API Server的请求。K8s默认有多个准入控制器，并且被编译进`kube-apiserver`二进制文件。执行命令

```shell
kube-apiserver -h | grep enable-admission-plugins
```

就可以看到，当前K8s集群默认启动的准入控制器插件有哪些。可以从官方文档了解各个准入控制器的作用：[What does each admission controller do?](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#what-does-each-admission-controller-do)

其中有两个特殊的、拥有极高的灵活性的控制器，也是我们本文主要关注的：`MutatingAdmissionWebhook`和`ValidatingAdmissionWebhook`，通常来说，它们分别负责**执行插入变更和校验**的工作。K8s的动态准入控制，目前主要也是指这两种`Webhook`，还有一种`Initializer`的机制，目前存在较长的时间未更新，暂不介绍。

Mutating webhook可以在资源对象请求时，通过创建补丁来修改对象；Validating webhook可以对请求进行校验和拒绝，但无法修改请求中的资源对象。

## Webhook使用原理

首先借用一张Webhook在K8s API请求声明周期中的流程图：

![](/img/k8s-webhook-intro/admission-controller-phases.png)

大致的作用流程如下：

1. 编写处理Webhook回调的Server，最常见的形式是一个HTTP服务，可以通过`service`进行暴露。
2. 确认集群开启了Admission controller，创建`MutatingWebhookConfiguration`和`ValidatingWebhookConfiguration`来配置Webhook作用的资源对象和回调的服务。

## 简单实践示例

首先要确认K8s集群启用了`MutatingAdmissionWebhook`和`ValidatingAdmissionWebhook`，以及根据K8s的版本选择对应的GroupVersion：

- K8s v1.16+：`admissionregistration.k8s.io/v1`
- K8s v1.9：`admissionregistration.k8s.io/v1beta1`

## kubebuilder构建Webhook

通常我们使用`kubebuilder`作为Operator的脚手架，它可以帮助我们方便的构建CRD和Controller的代码。同时，它也可以帮助我们在Operator中使用Admission webhooks。Kubebuilder帮助我们简化了在Operator中使用Webhook的操作流程， 我们仅仅需要编写`Defaulter`和`Validator`的逻辑即可。

Kubebuilder 会帮你处理其余无关业务逻辑的部分，比如下面这些：

1. 创建 Webhook 服务端。
2. 确保服务端已添加到 manager 中。
3. 为这些 Webhooks 创建处理函数。
4. 用路径在你的服务端中注册每个处理函数。

下面假定一个自定义资源类型`App`，使用`kubebuilder`初始化一个Operator框架，并部署Webhook。

### 初始化CRD和Controller

执行命令

```shell
$ go mod init xjin.com/demo-operator
$ # 初始化Operator项目框架
$ kubebuilder init --domain xjin.com --owner "xjin"
$ # 创建API、Controller代码
$ kubebuilder create api --group xjin --version v1 --kind App
$ # 生成CRD、RBAC等资源yaml
$ make manifest
```

然后将生成的CRD、RBAC等资源，apply到目标K8s集群上。

### 生成并编写Webhook

执行命令

```shell
$ kubebuilder create webhook --group xjin --version v1 --kind App --defaulting --programmatic-validation\
$ make manifests
```

分别生成了Webhook的代码和`WebhookConfiguration`资源yaml。执行完成后可以看到`api/v1`目录下生成了`app_webhook.go`，可以看到里面已经生成了webhook的接口方法，我们只需要编写我们需要的逻辑即可。下面是生成的代码片段：

```go
//+kubebuilder:webhook:path=/mutate-xjin-xjin-com-v1-app,mutating=true,failurePolicy=fail,sideEffects=None,groups=xjin.xjin.com,resources=apps,verbs=create;update,versions=v1,name=mapp.kb.io,admissionReviewVersions=v1

var _ webhook.Defaulter = &App{}

func (r *App) Default() {
	applog.Info("default", "name", r.Name)
  // TODO(user): fill in your defaulting logic.
}

//+kubebuilder:webhook:path=/validate-xjin-xjin-com-v1-app,mutating=false,failurePolicy=fail,sideEffects=None,groups=xjin.xjin.com,resources=apps,verbs=create;update,versions=v1,name=vapp.kb.io,admissionReviewVersions=v1
var _ webhook.Validator = &App{}

// ValidateCreate implements webhook.Validator so a webhook will be registered for the type
func (r *App) ValidateCreate() error {
	applog.Info("validate create", "name", r.Name)

	// TODO(user): fill in your validation logic upon object creation.
	return nil
}

// ValidateUpdate implements webhook.Validator so a webhook will be registered for the type
func (r *App) ValidateUpdate(old runtime.Object) error {
	applog.Info("validate update", "name", r.Name)

	// TODO(user): fill in your validation logic upon object update.
	return nil
}
```

`Defaulter`和`Validator`这两个interface就代表着`MutatingWebhookServer` 和 `ValidatingWebhookServer`。下面说明一下Webhook相关的`kubebuilder`作用注释

```go
//+kubebuilder:webhook:path=/mutate-xjin-xjin-com-v1-app,mutating=true,failurePolicy=fail,sideEffects=None,groups=xjin.xjin.com,resources=apps,verbs=create;update,versions=v1,name=mapp.kb.io,admissionReviewVersions=v1
```

- failurePolicy：当API Server与Webhook Server通信失败时的行为，可选`fail`和`ignore`。
- groups、resources：表示哪个GVR在发生变化时会触发Webhook请求。
- name：Webhook的名称，生成的Configuration资源中与此名称对应。
- path：Webhook处理请求的path，生成的Configuration资源中path与此处对应。
- verbs：表示在指定资源发生哪些变化时会触发Webhook。

## 实践中的用途

- 云原生社区中火热的`Istio`服务网格，就是通过Mutating webhooks来自动地将数据面`Envoy`作为sidecar注入到Pod中的。
- 对于自定义资源（CR, Custom resource），单个字段的类型、非空等校验规则我们可以在CRD中定义，但是对于具体值、或者多个字段组合起来的复杂校验，则可以通过Validating webhooks实现。
- 在中间件Operator开发过程中，各种CR可能会存在某种程度上的耦合或绑定。比如Kafka依赖的ZooKeeper是通过Operator部署的一种CR，那么删除该ZK的CR时，我们可以通过Webhook在删除请求时检查该ZK是否在管理着Kafka，如果有，则拒绝删除请求。
- 一个容器云管理平台中，可以自定义配额管理机制，比如根据Pod上的Label区分所属租户，对租户进行配额限制，超出租户配额限制，即使物理资源足够，也会拒绝Pod创建。
- ......

## 参考

- https://blog.hdls.me/15564491070483.html
- https://cloudnative.to/blog/mutating-admission-webhook/ 
- https://blog.hdls.me/15708754600835.html
