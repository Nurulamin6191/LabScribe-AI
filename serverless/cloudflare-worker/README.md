# LabScribe AI Serverless Gateway (Cloudflare Workers AI)

A serverless AI proxy for trying demo responses without endpoint setup for LabScribe AI users.

### Features
- **Zero API keys required by end users**: The app connects directly to your Worker.
- **Zero CLI or server setup**: No Ollama, no Docker, no ports, no localhost.
- **Powered by Open Models**:
  - **Speech-to-Text**: `@cf/openai/whisper`
  - **Reasoning LLM**: `@cf/meta/llama-3.1-8b-instruct` (or `@cf/meta/llama-3.3-70b-instruct-fp8-fast`)
- **Free tier**: Uses Cloudflare Workers AI free tier (10,000 neurons / day, no credit card required).

---

## Deployment Option 1: 60-Second Web Dashboard (Zero CLI / No Terminal)

1. Log into your free [Cloudflare Dashboard](https://dash.cloudflare.com/).
2. In the left sidebar, click **Workers & Pages** $\rightarrow$ **Create Application** $\rightarrow$ **Create Worker**.
3. Name it `labscribe-ai-gateway` and click **Deploy**.
4. Click **Edit Code**:
   - Replace the code in `index.js` with the contents of [`src/index.js`](./src/index.js).
   - Click **Deploy** (top-right).
5. In your worker's **Settings** $\rightarrow$ **Bindings**:
   - Click **Add** $\rightarrow$ select **Workers AI**.
   - Set the Variable Name to `AI`.
   - Click **Save and Deploy**.
6. Copy your Worker URL:
   `https://labscribe-ai-gateway.<your-subdomain>.workers.dev`

---

## Deployment Option 2: 1-Line Command Line (`npx wrangler`)

If you have Node.js installed on your machine:
```bash
cd serverless/cloudflare-worker
npx wrangler deploy
```
Wrangler will authenticate with Cloudflare and publish your worker in 10 seconds.

---

## Connecting to LabScribe AI

In the LabScribe Flutter app (or set as the app's default in `ConfigService`):
- **LLM Base URL**: `https://labscribe-ai-gateway.<your-subdomain>.workers.dev/v1`
- **Transcription Base URL**: `https://labscribe-ai-gateway.<your-subdomain>.workers.dev/v1`
- **API Key**: Leave blank (not needed!)

Now any user who downloads your Android APK or Desktop app gets instant Whisper audio transcription and Llama 3.1 analysis without additional setup in the app.
