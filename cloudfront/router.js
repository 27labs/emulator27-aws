// CloudFront Function (viewer request) for https://e27.samuelbido.com
//
//   curl -fsSL https://e27.samuelbido.com/aws | sudo bash
//
// Maps /aws to the installer object in the S3 bucket and answers everything
// else with a 404, so no other path ever reaches the bucket.
// Deployed by terraform/main.tf.
function handler(event) {
  var request = event.request;

  if (request.uri === "/aws" || request.uri === "/aws/") {
    request.uri = "/install.sh";
    return request;
  }

  return {
    statusCode: 404,
    statusDescription: "Not Found",
    headers: {
      "content-type": { value: "text/plain; charset=utf-8" },
      "x-content-type-options": { value: "nosniff" },
    },
    body: { encoding: "text", data: "Not found\n" },
  };
}
