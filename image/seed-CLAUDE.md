# claude-box

You are running inside a claude-box container. The project is in /workspace/<name>; nothing else from
the host is available. Credentials are injected per project as environment variables.
kubectl/k9s port-forwards in the box are also opened on localhost on the user's Mac (same port);
/tmp/claude-box-ports lists which ones are forwarded.
