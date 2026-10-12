# Dev image shared by every Node service of the stack.
# The project folder is bind-mounted at /app; dependencies live in a volume.
FROM node:24-slim

# tsx runs the TypeScript functions without a build step
RUN npm install -g tsx@4 && npm cache clean --force

COPY entrypoint.sh /usr/local/bin/kleoshq-entrypoint
COPY vercel-fn-server.mjs /opt/kleoshq/vercel-fn-server.mjs
RUN chmod +x /usr/local/bin/kleoshq-entrypoint

WORKDIR /app
ENV PORT=3000
EXPOSE 3000

ENTRYPOINT ["kleoshq-entrypoint"]
CMD ["tsx", "watch", "--clear-screen=false", "/opt/kleoshq/vercel-fn-server.mjs"]
