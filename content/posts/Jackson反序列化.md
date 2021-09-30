---
title: "Jackson反序列时未知字段的处理姿势"
date: 2019-10-27T11:17:30+08:00
draft: false
tags: ["JSON", "Java"]
categories: ["Java"]
featuredImagePreview: ""
summary: 假如我们的服务通过依赖另一个服务的REST接口，需要对它的返回进行序列化/反序列化，但依赖服务的接口字段可能会扩充，这时我们的Jackson默认的反序列化可能就会报`Unrecognized field`的错误，本文介绍Jackson正确的序列化/反序列化处理方式，
---

> 假如我们的服务通过依赖另一个服务的REST接口，需要对它的返回进行序列化/反序列化，但依赖服务的接口字段可能会扩充，这时我们的Jackson默认的反序列化可能就会报`Unrecognized field`的错误，本文介绍Jackson正确的序列化/反序列化处理方式。

## 问题分析

举个例子，在最简单的使用Jackson进行反序列化的场景下，我们的用法大致如下

```java
// 假设我们的使用的类如下
public class User {
  private String name;
  private String email;
}
```

接口返回的JSON

```json
{"name": "xjin", "email": "test@email"}
```

Jackson反序列化代码片段

```java
// 举例http客户端采用restTemplate
ResponseEntity<JsonNode> response = restTemplate.exchange(url, HttpMethod.GET, httpEntity, JsonNode.class, paramMap);
String jsonStr = mapper.writeValueAsString(response.getBody());
ObjectMapper mapper = new ObjectMapper();
User user = mapper.readValue(jsonStr, User.class);
```

这时还是正常运作的，如果接口返回多了一个`address`字段，JSON变成了这样

```json
{"name": "xjin", "email": "test@email", "address": "China"}
```

这个时候就会报`UnrecognizedPropertyException`异常，总之，只要JSON中的某个属性没有映射到其Java对象，Jackson都会抛出此异常。

## 处理方法

通常情况下，依赖服务的接口并不仅仅是为我们服务的，所以我们无法要求他们的响应不扩充字段，但怎样能使字段的增加不对我们的反序列化造成影响呢，目前有两种方法：

1. 在目标类上添加注解`@JsonIgnorePropertie(ignoreUnknown = true)`
2. `ObjectMapper`配置`FAIL_ON_UNKNOWN_PROPERTIES`，设置为`false`

两种方法代码分别如下所示

```java
@JsonIgnoreProperties(ignoreUnknown=true)
public class User {
  private String name;
  private String email;
}
```

```java
//...
objectMapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
//...
```

## 总结

经过验证，两种方法都可以解决”未知字段导致反序列化异常“的问题，但是哪种方法更好些呢？我个人认为使用`ObjectMapper`配置的方式更好，因为

- 大多数接口响应包装类都需要进行处理，每个类都要手动加注解，容易遗漏。
- 在Spring项目中，我们可以根据需要定义两个`ObjectMapper`作为两个`Bean`对象，分别是配置`FAIL_ON_UNKNOWN_PROPERTIES=false`的和默认的，这样我们可以根据需要选择是否在出现未知字段时报错还是正常返回。

## 补充

- 实际使用时还有发现这个异常`cannot deserialize from Object value (no delegate- or property-based Creator)`，这是因为反序列化是需要对应类有**无参构造方法**，但实际使用时发现有的类没有定义无参构造方法也能正常解析，后来了解到，JVM是会给类默认创建无参构造方法的，但由于我给对应的类手动写了带参数的构造方法，JVM就不会默认帮我创建无参的，需要自己手动写上去。
- 目前的使用中，是将Http响应用`JsonNode`接收，然后序列化成JSON串，再反序列化成对象，相当于做了两次，效率较低，之后可以考虑直接接收Http响应Body字符串，只进行一次反序列化。