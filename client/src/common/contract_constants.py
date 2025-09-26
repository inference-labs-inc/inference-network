from enum import IntEnum


class TaskStructMap(IntEnum):
    """
    Task model representation, declared in `contracts/interfaces/ISertnTaskManager.sol`
    Basically it's just a fields order in the `ISertnTaskManager.Task` struct.
    """

    START_BLOCK = 0
    START_TIME = 1
    MODEL_ID = 2
    INPUTS = 3
    PROOF_HASH = 4
    USER = 5
    NONCE = 6
    OPERATOR = 7
    STATE = 8
    OUTPUT = 9
    FEE = 10


class TaskStateMap(IntEnum):
    """
    Python representation for task states, declared in `contracts/interfaces/ISertnTaskManager.sol`
    `ISertnTaskManager.TaskState`
    """

    CREATED = 0
    ASSIGNED = 1
    COMPLETED = 2
    CHALLENGED = 3
    REJECTED = 4
    RESOLVED = 5

    def __str__(self):
        return self.name

    @classmethod
    def from_int(cls, value: int):
        """Convert integer from blockchain to TaskState"""
        try:
            return cls(value)
        except ValueError:
            raise ValueError(f"Invalid task state value: {value}")


class ContractVerificationStrategy(IntEnum):
    """
    Python representation of `VerificationStrategy` enum.
    """

    NONE = 0
    ONCHAIN = 1
    OFFCHAIN = 2
