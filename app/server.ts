import { existsSync } from "node:fs";
import { join, normalize } from "node:path";

const port = Number(process.env.PORT || 8080);
const root = join(import.meta.dir, "build", "web");
const indexPath = join(root, "index.html");

const contentTypes: Record<string, string> = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
};

function contentType(pathname: string): string {
  const dot = pathname.lastIndexOf(".");
  if (dot === -1) return "application/octet-stream";
  return contentTypes[pathname.slice(dot)] ?? "application/octet-stream";
}

function resolveStaticPath(pathname: string): string | null {
  const decoded = decodeURIComponent(pathname.split("?")[0] || "/");
  const relative = decoded === "/" ? "index.html" : decoded.replace(/^\/+/, "");
  const resolved = normalize(join(root, relative));
  return resolved.startsWith(root) ? resolved : null;
}

Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/api/health") {
      return Response.json({
        status: "ok",
        app: "wingman-app-flutter-web",
        build: existsSync(indexPath) ? "present" : "missing",
      });
    }

    const staticPath = resolveStaticPath(url.pathname);
    if (staticPath && existsSync(staticPath)) {
      return new Response(Bun.file(staticPath), {
        headers: {
          "content-type": contentType(staticPath),
        },
      });
    }

    if (existsSync(indexPath)) {
      return new Response(Bun.file(indexPath), {
        headers: {
          "content-type": "text/html; charset=utf-8",
        },
      });
    }

    return new Response("Flutter web build missing. Run `flutter build web`.", {
      status: 503,
      headers: {
        "content-type": "text/plain; charset=utf-8",
      },
    });
  },
});

console.log(`Wingman App Flutter web server listening on :${port}`);
