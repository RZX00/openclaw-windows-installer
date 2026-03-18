---
name: agent-reach
description: >
  Give your AI agent eyes to see the entire internet. Install and configure
  upstream tools for Twitter/X, Reddit, YouTube, GitHub, Bilibili, XiaoHongShu,
  Douyin, LinkedIn, Boss直聘, WeChat (微信公众号), RSS, and any web page — then call them directly.
  Use when: (1) setting up platform access tools for the first time,
  (2) checking which platforms are available,
  (3) user asks to configure/enable a platform channel.
  Triggers: "帮我配", "帮我添加", "帮我安装", "agent reach", "install channels",
  "configure twitter", "enable reddit".
metadata: { "openclaw": { "os": ["win32"], "requires": { "bins": ["agent-reach", "mcporter", "xreach", "gh"] } } }
---

# Agent Reach

Install and configure upstream tools for 12+ platforms. After setup, call them directly.

## Packaged Windows install

On this Windows installer distribution, prefer the curated Workflow Zone add-on package instead of running `pip install` manually.

Expected commands after the add-on is installed:

```bash
agent-reach doctor
agent-reach watch
agent-reach check-update
```

If these commands are missing, the local Workflow Zone package has not been installed correctly yet. Ask the operator to install or repair the matching workflow add-on package first.

## Fallback upstream install

If you are not on the packaged Windows distribution, the upstream fallback remains:

```bash
pip install https://github.com/Panniantong/agent-reach/archive/main.zip
agent-reach install --env=auto
agent-reach doctor
```

`install` auto-detects your environment and installs core dependencies (Node.js, mcporter, xreach CLI, gh CLI, yt-dlp, feedparser). Run `doctor` to see what's active.

## Management

```bash
agent-reach doctor        # channel status overview
agent-reach watch         # quick health + update check
agent-reach check-update  # check for new versions
```

## Configure channels

```bash
agent-reach configure twitter-cookies "auth_token=xxx; ct0=yyy"
agent-reach configure proxy http://user:pass@ip:port
agent-reach configure --from-browser chrome
```

## Configuring a channel ("帮我配 XXX")

When a user asks to configure or enable any channel:

1. Run `agent-reach doctor`
2. Find the channel - it shows status and what to do next
3. Execute what you can automatically
4. For human-required steps (for example cookies), tell the user what to do
5. Run `agent-reach doctor` again to verify

Do not memorize per-channel setup steps. Always rely on `doctor` output.

### Cookie 导入（所有需要登录的平台通用）

> ⚠️ 重要提醒：使用 Cookie 登录的平台存在封号风险，请提醒用户务必使用专用小号。

所有需要 Cookie 的平台（Twitter、小红书等），优先使用 Cookie-Editor 导入：

1. 用户在自己的浏览器登录对应平台
2. 安装 [Cookie-Editor](https://chromewebstore.google.com/detail/cookie-editor/hlkenndednhfkekhgcdicdfddnkalmdm) Chrome 插件
3. 点击插件 -> Export -> Header String
4. 把导出的字符串发给 Agent

本地电脑用户也可以用 `agent-reach configure --from-browser chrome` 一键自动提取。

### Other human actions

- Proxy: Reddit / Bilibili / XiaoHongShu may block server IPs — suggest a residential proxy if on a server

## Using Upstream Tools Directly

After `agent-reach install`, call the upstream tools directly.

> Note: `agent-reach` is an installer and config tool - it does not have `read`, `search`, or content-fetching commands. Use the upstream tools below instead.

### Twitter/X (xreach CLI)

```bash
xreach search "query" --json -n 10
xreach tweet https://x.com/user/status/123 --json
xreach tweets @username --json -n 20
```

### YouTube (yt-dlp)

```bash
yt-dlp --dump-json "https://www.youtube.com/watch?v=xxx"
yt-dlp --write-sub --write-auto-sub --sub-lang "zh-Hans,zh,en" --skip-download -o "/tmp/%(id)s" "URL"
yt-dlp --dump-json "ytsearch5:query"
```

### Bilibili (yt-dlp)

```bash
yt-dlp --dump-json "https://www.bilibili.com/video/BVxxx"
yt-dlp --write-sub --write-auto-sub --sub-lang "zh-Hans,zh,en" --convert-subs vtt --skip-download -o "/tmp/%(id)s" "URL"
yt-dlp --cookies-from-browser chrome --dump-json "URL"
```

### Reddit (JSON API)

```bash
curl -s "https://www.reddit.com/r/python/hot.json?limit=10" -H "User-Agent: agent-reach/1.0"
curl -s "https://www.reddit.com/r/python/comments/POST_ID.json" -H "User-Agent: agent-reach/1.0"
curl -s "https://www.reddit.com/search.json?q=query&limit=10" -H "User-Agent: agent-reach/1.0"
```

### 小红书 / XiaoHongShu (mcporter + xiaohongshu-mcp)

```bash
mcporter call 'xiaohongshu.search_feeds(keyword: "query")'
mcporter call 'xiaohongshu.get_feed_detail(feed_id: "xxx", xsec_token: "yyy")'
mcporter call 'xiaohongshu.get_feed_detail(feed_id: "xxx", xsec_token: "yyy", load_all_comments: true)'
mcporter call 'xiaohongshu.publish_content(title: "标题", content: "正文", images: ["/path/to/img.jpg"], tags: ["美食"])'
mcporter call 'xiaohongshu.publish_with_video(title: "标题", content: "正文", video: "/path/to/video.mp4", tags: ["vlog"])'
```

### 抖音 / Douyin (mcporter + douyin-mcp-server)

```bash
mcporter call 'douyin.parse_douyin_video_info(share_link: "https://v.douyin.com/xxx/")'
mcporter call 'douyin.get_douyin_download_link(share_link: "https://v.douyin.com/xxx/")'
mcporter call 'douyin.extract_douyin_text(share_link: "https://v.douyin.com/xxx/")'
```

### GitHub (gh CLI)

```bash
gh search repos "query" --sort stars --limit 10
gh repo view owner/repo
gh search code "query" --language python
gh issue list -R owner/repo --state open
gh issue view 123 -R owner/repo
```

### Web - Any URL (Jina Reader)

```bash
curl -s "https://r.jina.ai/URL" -H "Accept: text/markdown"
curl -s "https://s.jina.ai/query" -H "Accept: text/markdown"
```

### Exa Search (mcporter + exa MCP)

```bash
mcporter call 'exa.web_search_exa(query: "query", numResults: 5)'
mcporter call 'exa.get_code_context_exa(query: "how to parse JSON in Python", tokensNum: 3000)'
mcporter call 'exa.company_research_exa(companyName: "OpenAI")'
```

### LinkedIn (mcporter + linkedin-scraper-mcp)

```bash
mcporter call 'linkedin.get_person_profile(linkedin_url: "https://linkedin.com/in/username")'
mcporter call 'linkedin.search_people(keyword: "AI engineer", limit: 10)'
mcporter call 'linkedin.get_company_profile(linkedin_url: "https://linkedin.com/company/xxx")'
```

### Boss直聘 (mcporter + mcp-bosszp)

```bash
mcporter call 'bosszhipin.get_recommend_jobs_tool(page: 1)'
mcporter call 'bosszhipin.search_jobs_tool(keyword: "Python", city: "北京", page: 1)'
mcporter call 'bosszhipin.get_job_detail_tool(job_url: "https://www.zhipin.com/job_detail/xxx")'
```

### 微信公众号 (wechat-article-for-ai + miku_ai)

Search:

```python
python3 -c "
import asyncio
from miku_ai import get_wexin_article

async def search():
    articles = await get_wexin_article('AI Agent', 5)
    for a in articles:
        print(f'{a[\"title\"]} | {a[\"source\"]} | {a[\"date\"]}')
        print(f'  {a[\"url\"]}')

asyncio.run(search())
"
```

Read:

```bash
cd /path/to/wechat-article-for-ai && python3 main.py "https://mp.weixin.qq.com/s/ARTICLE_ID"
python3 mcp_server.py
```

### RSS (feedparser)

```python
python3 -c "
import feedparser
d = feedparser.parse('https://example.com/feed')
for e in d.entries[:5]:
    print(f'{e.title} — {e.link}')
"
```

## Troubleshooting

### Twitter "fetch failed"

xreach CLI uses Node.js `undici`, which does not respect `HTTP_PROXY`. Solutions:

1. Ensure `undici` is installed: `npm install -g undici`
2. Configure proxy: `agent-reach configure proxy http://user:pass@ip:port`
3. If still failing, use a transparent proxy

### Channel broken?

Run `agent-reach doctor` - it shows what is wrong and how to fix it.
