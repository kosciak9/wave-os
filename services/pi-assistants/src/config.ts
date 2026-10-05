import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import type { Models } from "@earendil-works/pi-ai";

export type Config = {
  botToken: string;
  ownerId: string;
  model: { provider: string; modelId: string };
};

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Invalid configuration");
  }
  return value as Record<string, unknown>;
}

export function parseConfig(value: unknown): Config {
  const config = object(value);
  const model = object(config.model);
  const { botToken, ownerId } = config;
  if (
    typeof botToken !== "string" ||
    !/^\d+:[A-Za-z0-9_-]+$/.test(botToken) ||
    typeof ownerId !== "string" ||
    !/^[1-9]\d*$/.test(ownerId) ||
    !Number.isSafeInteger(Number(ownerId)) ||
    typeof model.provider !== "string" ||
    !model.provider.trim() ||
    typeof model.modelId !== "string" ||
    !model.modelId.trim()
  )
    throw new Error("Invalid configuration");
  return {
    botToken,
    ownerId,
    model: { provider: model.provider, modelId: model.modelId },
  };
}

export async function configuredModels(config: Config): Promise<Models> {
  const models = builtinModels();
  const provider = models.getProvider(config.model.provider);
  if (!provider || !(await models.getAuth(provider.id))) {
    throw new Error("Provider unavailable or unconfigured");
  }
  const refreshed = await models.refresh({ providers: [provider.id] });
  if (
    refreshed.errors.size ||
    !models.getModel(provider.id, config.model.modelId)
  ) {
    throw new Error("Selected model unavailable");
  }
  return models;
}
