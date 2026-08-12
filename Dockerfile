# The dev server in a container, for the "it works on my machine" conversation.
# Not a production image: platypad has no server side, so shipping it means
# copying dist/ onto any static host.

FROM node:22-alpine

# corepack ships with node 22 and pins pnpm from package.json, so the container
# and the laptop cannot disagree about the version.
RUN corepack enable

WORKDIR /app

# Dependencies first: this layer is only invalidated when the lockfile moves,
# which is what keeps a source-only change to a couple of seconds.
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .

EXPOSE 5173

# --host, or the port forward reaches a server bound to the container's loopback
# and nothing else.
CMD ["pnpm", "dev", "--host", "0.0.0.0"]
