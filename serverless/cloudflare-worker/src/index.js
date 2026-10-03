/**
 * LabScribe AI: Zero-Setup Serverless AI Gateway
 * 
 * Free serverless backend powered by Cloudflare Workers AI.
 * Implements standard OpenAI-compatible endpoints for:
 *   - Speech-To-Text: @cf/openai/whisper
 *   - Reasoning LLM : @cf/meta/llama-3.1-8b-instruct (or @cf/meta/llama-3.3-70b-instruct-fp8-fast)
 * 
 * End users require:
 *   - No API keys
 *   - No logins
 *   - No local servers or command-line dependencies
 */

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

export default {
  async fetch(request, env, ctx) {
    // 1. Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    try {
      // 2. Health & Status Check
      if (path === "/" || path === "/health") {
        return Response.json(
          {
            status: "ok",
            service: "LabScribe AI Serverless Gateway",
            architecture: "Cloudflare Workers AI",
            speechModel: "@cf/openai/whisper",
            reasoningModel: "@cf/meta/llama-3.1-8b-instruct",
            ready: true,
          },
          { headers: CORS_HEADERS }
        );
      }

      // 3. Models List (OpenAI compatibility)
      if (path === "/v1/models" || path === "/models") {
        return Response.json(
          {
            object: "list",
            data: [
              { id: "@cf/openai/whisper", object: "model", owned_by: "cloudflare" },
              { id: "@cf/meta/llama-3.1-8b-instruct", object: "model", owned_by: "cloudflare" },
              { id: "whisper-large-v3", object: "model", owned_by: "cloudflare" },
              { id: "llama-3.1-8b", object: "model", owned_by: "cloudflare" },
            ],
          },
          { headers: CORS_HEADERS }
        );
      }

      // 4. Speech-To-Text Transcription Endpoint
      // Expected by LabScribe: POST /v1/audio/transcriptions
      if (path.endsWith("/audio/transcriptions")) {
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
        }

        const contentType = request.headers.get("content-type") || "";
        if (!contentType.includes("multipart/form-data")) {
          return Response.json(
            { error: "Expected multipart/form-data with an audio file" },
            { status: 400, headers: CORS_HEADERS }
          );
        }

        const formData = await request.formData();
        const file = formData.get("file");

        if (!file || typeof file === "string") {
          return Response.json(
            { error: "Audio file field 'file' is required" },
            { status: 400, headers: CORS_HEADERS }
          );
        }

        const arrayBuffer = await file.arrayBuffer();
        const uint8Array = new Uint8Array(arrayBuffer);

        // Run Cloudflare Workers AI Whisper model
        const result = await env.AI.run("@cf/openai/whisper", {
          audio: [...uint8Array],
        });

        return Response.json(
          { text: result.text || "" },
          { headers: CORS_HEADERS }
        );
      }

      // 5. LLM Chat Completions Endpoint
      // Expected by LabScribe: POST /v1/chat/completions
      if (path.endsWith("/chat/completions")) {
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
        }

        const body = await request.json();
        const messages = body.messages || [];

        if (!messages.length) {
          return Response.json(
            { error: "Messages array cannot be empty" },
            { status: 400, headers: CORS_HEADERS }
          );
        }

        // Run Cloudflare Workers AI Llama model
        const modelToUse = env.LLM_MODEL || "@cf/meta/llama-3.1-8b-instruct";
        const aiResponse = await env.AI.run(modelToUse, {
          messages: messages,
          max_tokens: 3000,
          temperature: body.temperature || 0.2,
        });

        const replyText = aiResponse.response || "";

        // Return standard OpenAI JSON schema
        return Response.json(
          {
            id: `chatcmpl-${Date.now()}`,
            object: "chat.completion",
            created: Math.floor(Date.now() / 1000),
            model: modelToUse,
            choices: [
              {
                index: 0,
                message: {
                  role: "assistant",
                  content: replyText,
                },
                finish_reason: "stop",
              },
            ],
            usage: {
              prompt_tokens: 0,
              completion_tokens: 0,
              total_tokens: 0,
            },
          },
          { headers: CORS_HEADERS }
        );
      }

      // Default Not Found
      return new Response("Not Found", { status: 404, headers: CORS_HEADERS });

    } catch (err) {
      console.error("Worker error:", err);
      return Response.json(
        {
          error: {
            message: err.message || "Internal Worker Error",
            type: "gateway_error",
          },
        },
        { status: 500, headers: CORS_HEADERS }
      );
    }
  },
};
