# repository-connection Specification

## Purpose

让用户通过 GitHub 或 Gitee 的账号授权连接自己可访问的私有仓库，并选择用于保存照片密文的目标位置，同时将仓库访问授权与照片解密密码、应用锁密码的用途保持清楚区分。

## Requirements

### Requirement: 支持两种平台授权

应用 SHALL 提供 GitHub 和 Gitee 两种授权登录入口；具体授权协议流程、权限范围和令牌管理方案尚待确定。

#### Scenario: 使用 GitHub 授权
- **WHEN** 用户选择 GitHub 作为仓库平台
- **THEN** 应用提供 GitHub 账号授权流程

#### Scenario: 使用 Gitee 授权
- **WHEN** 用户选择 Gitee 作为仓库平台
- **THEN** 应用提供 Gitee 账号授权流程

### Requirement: 选择私有仓库

应用 SHALL 允许用户在所选平台授权后选择可访问的私有仓库，作为加密照片副本的同步目标。

#### Scenario: 配置同步位置
- **WHEN** 用户完成平台授权并选择一个可访问的私有仓库
- **THEN** 应用记录该私有仓库作为所配置的照片库同步目标
- **AND** 上传内容仍须满足 encrypted-storage 的客户端加密要求

### Requirement: 凭据用途分离

应用 SHALL 区分平台授权、照片解密密码和四位应用锁，不能把平台授权完成或应用锁解锁当作照片解密密码验证成功。

#### Scenario: 授权不能解除到期验证
- **WHEN** 照片解密密码验证已经到期，用户重新完成 GitHub 或 Gitee 授权
- **THEN** 照片访问和同步仍等待正确的照片解密密码验证
