{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
}:

buildNpmPackage {
  pname = "mac-apps-mcp-server";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "captainmark23";
    repo = "mac-apps-mcp";
    rev = "fc348ce60685db63a24767cff1bc3aae212b1f8f";
    hash = "sha256-RUzyN5MR6uWZZqV/XWG7ZKWLJDmNsaiWrt7xBUjyCRg=";
  };

  npmDepsHash = "sha256-anXl6ypr1CbnERIpU3x35RgzLMNfVdi82/AjgfnnWvs=";

  meta = {
    description = "MCP server for macOS Mail, Calendar, Reminders, and Contacts";
    homepage = "https://github.com/captainmark23/mac-apps-mcp";
    license = lib.licenses.mit;
    mainProgram = "mac-apps-mcp-server";
    platforms = lib.platforms.darwin;
  };
}
