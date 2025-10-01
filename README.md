# geminiproxy
一键gemini反代安装脚本

基于Ubuntu Debian CentOS ArchLinux发行linux

使用nginx反代需要预先准备好ssl证书

安装完成后将域名解析至你主机的公网ip

注意这里不是将gemini标准格式转换成openai格式注意甄别

将您的域名填入chatbox等ai聊天软件内即可

# 具体流程

1、获得一个服务器

服务器可以是NAT＆独立IP服务器，这里以ｓａｄｉｄｃ．ｃｎ的澳大利亚ＮＡＴ主机为例

１.１、登陆服务器

ｉｍｇ／１．ｊｐｇ

找到登录用户名（一般为ｒｏｏｔ用户）并找到登录密码

检查机器状态（是否为开机状态如果不是手动开机）

使用Xshell、ＦｉｎａｌＳｈｅｌｌ等ｓｓｈ远程终端登录你的服务器

ｉｍｇ／２．ｊｐｇ

２、安装服务

复制部署代码

ｉｍｇ／３．ｊｐｇ

粘贴到终端并回车

ｉｍｇ／４．ｊｐｇ

会看到一个管理面板我们输入１安装反代

随后会让我们输入信息

（需要输入域名、映射端口、ｓｓｌ证书获取方式（注意ｎａｔ机仅可以使用第４个方法））

ｉｍｇ／５．ｊｐｇ

这里安装过就不演示了

随后将你的域名解析到服务器公网ｉｐ（ｎａｔ机需要映射端口再解析）

３、如何使用

打开ｃｈａｔｂｏｘ　ａｐｐ或者ｗｅｂ版

ｉｍｇ／６．ｊｐｇ

点击设置

ｉｍｇ／７．ｊｐｇ

填入相关信息（Gemini的APIｋｅｙ需要自己翻墙上ａｉ．ｄｅｖ获取）

随后就可以与ｇｅｍｉｎｉ畅聊了

＃　注意事项

建议使用马来西亚、韩国、日本等亚欧服务器否则对话可能会出现卡顿等情况影响对话体验

安装命令：
```shell
wget https://raw.githubusercontent.com/Cnfte/geminiproxy/refs/heads/main/proxy.sh
```
```shell
sudo bash proxy.sh
```
或：
```shell
wget https://raw.githubusercontent.com/Cnfte/geminiproxy/refs/heads/main/proxy.sh && sudo bash proxy.sh
```
