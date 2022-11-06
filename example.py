from typing import Any, Callable, List, Tuple

import torch
from torch import _dynamo as dynamo
from torch import _inductor as inductor
from torch._inductor import compile_fx

import torch._inductor.config
inductor.config.debug = True

import torch._dynamo.config
dynamo.config.verbose = True

import torchvision

from functorch import vmap # TODO

CompileFunc = Callable[[torch.fx.GraphModule, List[torch.Tensor]], Callable[..., Any]]
def wrap_compiler(
    compile: CompileFunc
) -> CompileFunc:
    def compiler(
        fx_graph: torch.fx.GraphModule,
        example_inputs: List[torch.Tensor],
    ) -> Callable[..., Any]:
        # sep = 100 * "-"
        # print(f"got graph: {sep}\n{fx_graph.print_readable()}\n{sep}")
        # print(fx_graph)

        # print("compiling...")
        return compile(fx_graph, example_inputs)

    return compiler

compiler = wrap_compiler(compile_fx.compile_fx)

@dynamo.optimize(compiler)
def simple(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    print(a)
    print(b)
    return torch.add(a, b)

print("Add result: ", simple(torch.randn(1), torch.randn(1)))
print("Add result: ", simple(torch.randn(1), torch.randn(1)))

@dynamo.optimize(compiler)
def op(a: torch.Tensor, b: torch.Tensor, c: torch.Tensor) -> torch.Tensor:
    return torch.relu(torch.matmul(torch.add(0.5 * a, b), c))

op(torch.randn(128, 8192), torch.randn(128, 8192), torch.randn(8192, 128))

import requests

def get_date_from_gh_commit(owner: str, repo: str, commit: str) -> Tuple[str, str]:
    date = "Unknown"
    if commit != "Unknown":
        resp = requests.get(
            f"https://api.github.com/repos/{owner}/{repo}/commits/{commit}",
            headers = {
                "Accept": "application/vnd.github+json"
            },
        ).json()

        date = resp["commit"]["committer"]["date"]

    print(f"{owner}/{repo} @ {commit} -> {date}")
    print(f"   - https://github.com/{owner}/{repo}/commit/{commit}")
    return date

print("")
get_date_from_gh_commit("pytorch", "pytorch", torch.version.git_version)
get_date_from_gh_commit("pytorch", "vision", torchvision.version.git_version)
