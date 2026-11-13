// Serves the installer at https://e27.samuelbido.com/aws
//
//   curl -fsSL https://e27.samuelbido.com/aws | sudo bash
//
// install.sh is bundled into the Worker as text at deploy time.
import installer from "../install.sh";

export default {
  fetch(request) {
    const url = new URL(request.url);
    const { pathname } = url;

    // The script is piped into a root shell, so never serve it over plain HTTP.
    if (url.protocol === "http:") {
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed\n", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    if (pathname === "/aws" || pathname === "/aws/") {
      return new Response(installer, {
        headers: {
          "Content-Type": "text/plain; charset=utf-8",
          "Cache-Control": "public, max-age=300",
          "X-Content-Type-Options": "nosniff",
        },
      });
    }

    return new Response("Not found\n", { status: 404 });
  },
};
