// CloudFront Function (viewer request) that serves the installer.
//
// Maps the installer path to the script in the S3 bucket and answers
// everything else with a 404, so no other path ever reaches the bucket.
//
// Deployed by terraform/main.tf, which replaces the placeholder below with
// the `path` variable.
var INSTALLER_PATH = "${path}";

function handler(event) {
  var request = event.request;

  if (request.uri === INSTALLER_PATH || request.uri === INSTALLER_PATH + "/") {
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
