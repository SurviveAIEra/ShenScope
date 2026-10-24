"""Inference-only replacement of one residual/RMSNorm boundary per Llama layer.

Attention, RoPE, cache updates, MLP, final normalization and the language head
remain the existing Transformers modules. The native path is a stronger baseline
using torch.nn.functional.rms_norm at the same boundary.
"""
import types

import torch
import torch.nn.functional as F
from transformers.models.llama.modeling_llama import LlamaDecoderLayer


class ResidualNormAdapter:
    def __init__(self, model, mode, bridge=None):
        if mode not in {"control", "torch_native", "julia"}:
            raise ValueError("unsupported adapter mode")
        if mode == "julia" and bridge is None:
            raise ValueError("Julia mode requires a real initialized bridge")
        if model.training or any(parameter.requires_grad for parameter in model.parameters()):
            raise ValueError("model must be eval with gradients disabled")
        if model.config.model_type != "llama":
            raise ValueError("only the built-in Llama model is supported")
        self.mode, self.bridge = mode, bridge
        self.calls = 0
        self.layout_copies = 0
        self._originals = []
        layers = list(model.model.layers)
        if not layers or any(type(layer) is not LlamaDecoderLayer for layer in layers):
            raise ValueError("unexpected decoder layers; no partial patch was applied")
        for layer in layers:
            self._originals.append((layer, layer.forward))
            layer.forward = types.MethodType(self._make_forward(), layer)

    def _make_forward(self):
        owner = self

        def forward(layer, hidden_states, attention_mask=None, position_ids=None,
                    past_key_values=None, use_cache=False, position_embeddings=None, **kwargs):
            if torch.is_grad_enabled():
                raise RuntimeError("adapter calls require inference_mode or no_grad")
            normalized_input = layer.input_layernorm(hidden_states)
            attention, _ = layer.self_attn(normalized_input, attention_mask=attention_mask,
                position_ids=position_ids, past_key_values=past_key_values,
                use_cache=use_cache, position_embeddings=position_embeddings, **kwargs)
            if owner.mode == "julia":
                if not attention.is_contiguous():
                    attention = attention.contiguous()
                    owner.layout_copies += 1
                if not hidden_states.is_contiguous():
                    hidden_states = hidden_states.contiguous()
                    owner.layout_copies += 1
                normalized = torch.empty_like(attention)
                residual_sum = torch.empty_like(attention)
                weight = layer.post_attention_layernorm.weight
                owner.bridge.add_rmsnorm_into(attention.view(-1, layer.hidden_size),
                    hidden_states.view(-1, layer.hidden_size), weight,
                    normalized.view(-1, layer.hidden_size), residual_sum.view(-1, layer.hidden_size),
                    layer.post_attention_layernorm.variance_epsilon)
            else:
                residual_sum = hidden_states + attention
                if owner.mode == "torch_native":
                    normalized = F.rms_norm(residual_sum, (layer.hidden_size,),
                        layer.post_attention_layernorm.weight,
                        layer.post_attention_layernorm.variance_epsilon)
                else:
                    normalized = layer.post_attention_layernorm(residual_sum)
            owner.calls += 1
            return residual_sum + layer.mlp(normalized)

        return forward

    def restore(self):
        for layer, original in self._originals:
            layer.forward = original
        self._originals.clear()
