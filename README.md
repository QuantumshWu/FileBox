# FileBox

自用的 iPhone 文件管理器（Readdle Documents 的无广告替代品）。

- 在任何 App 里点「分享」→ **FileBox**，图片、视频、文件会存进 FileBox 的「收件箱」
- 浏览、搜索、重命名、删除、新建文件夹，点开直接预览图片 / 视频 / PDF 等
- 文件也能在系统「文件」App →「我的 iPhone」→ FileBox 里看到

## 构建

不需要 Mac。每次推送到 `main`，GitHub Actions 会在云端 Mac 上用 XcodeGen 生成工程、编译出未签名的
`FileBox.ipa`，连同 SideStore 用的 `source.json` 一起发布到 Releases。

## 安装（免费 Apple ID 自签）

用 SideStore 安装并每 7 天自动续签。在 SideStore 里添加源：

```
https://github.com/QuantumshWu/FileBox/releases/latest/download/source.json
```

或者下载最新 Release 里的 `FileBox.ipa`，在 SideStore 的「我的 App」里点 + 选择它。
安装时如果提示 App 包含扩展，选择**保留扩展（Keep App Extensions）**，否则分享菜单里不会出现 FileBox。
