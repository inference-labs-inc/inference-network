import torch


def field_element_to_input(value: float, scale: int = 2) -> float:
    """Convert a field element to input value by applying scale factor.

    Args:
        value: The field element value to convert.
        scale: The scale factor (default: 2).

    Returns:
        Converted float value.
    """
    return value * 2 ** (-scale)


def parse_input(raw_input: list[str], scale: int = 2) -> torch.Tensor:
    """Parse a given list of input strings into a tensor.

    Args:
        raw_input: List of input strings to parse.
        scale: The scale factor for field element conversion (default: 2).

    Returns:
        Tensor containing the parsed and scaled input values.
    """
    if len(raw_input) == 1:
        formatted_input = torch.tensor(
            [field_element_to_input(float(i), scale) for i in raw_input[0].split(" ")]
        )
    else:
        formatted_input = torch.tensor(
            [field_element_to_input(float(i), scale) for i in raw_input]
        )

    return formatted_input
