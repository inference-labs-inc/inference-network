// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IModelRegistry {
    /**
     * @notice The strategy used to verify the model
     * XXX: changing this struct, don't forget to take care of `client/src/common/contract_constants.py`
     */
    enum VerificationStrategy {
        None,
        Onchain,
        Offchain
    }
    /**
     * @notice The event emitted when a new model is created
     * @param modelId The id of the model
     * @param modelVerifier The address of the model verifier
     * @param verificationStrategy The strategy used to verify the model
     * @param modelName The name of the model (unique)
     * @param computeCost The compute cost of the model
     */
    event ModelCreated(
        uint256 indexed modelId,
        address indexed modelVerifier,
        VerificationStrategy indexed verificationStrategy,
        string modelName,
        uint256 computeCost,
        uint256 requiredFUCUs
    );
    /**
     * @notice The event emitted when a model name is updated
     * @param modelId The id of the model
     * @param modelName The name of the model (unique)
     */
    event ModelNameUpdated(uint256 indexed modelId, string indexed modelName);
    /**
     * @notice The event emitted when the compute cost of a model is updated
     * @param modelId The id of the model
     * @param computeCost The new compute cost of the model
     */
    event ComputeCostUpdated(uint256 indexed modelId, uint256 indexed computeCost);

    /**
     * @notice The event emitted when the required FUCUs of a model is updated
     * @param modelId The id of the model
     * @param requiredFUCUs The new required FUCUs of the model
     */
    event RequiredFUCUsUpdated(uint256 indexed modelId, uint256 indexed requiredFUCUs);

    /**
     * @notice The event emitted when a model verifier is updated
     * @param modelId The id of the model
     * @param modelVerifier The address of the model verifier
     */
    event ModelVerifierUpdated(uint256 indexed modelId, address indexed modelVerifier);

    /**
     * @notice The event emitted when a verification strategy is updated
     * @param modelId The id of the model
     * @param verificationStrategy The new verification strategy of the model
     */
    event VerificationStrategyUpdated(
        uint256 indexed modelId,
        VerificationStrategy indexed verificationStrategy
    );

    /**
     * @notice Emitted when a model is disabled (made unusable)
     * @param modelId The id of the model
     */
    event ModelDisabled(uint256 indexed modelId);

    /**
     * @notice The error emitted when a model already exists
     * @param modelId The id of the model
     */
    error ModelAlreadyExists(uint256 modelId);
    /**
     * @notice The error emitted when a model verifier is invalid
     */
    error InvalidModelVerifier();
    /**
     * @notice The error emitted when a model does not exist
     */
    error ModelDoesNotExist();
    /**
     * @notice The error emitted when no active models exist
     */
    error NoActiveModels();
    /**
     * @notice The error emitted when a model name is empty
     */
    error InvalidModelName();

    /**
     * @notice The function to create a new model
     * @param modelVerifier The address of the model verifier
     * @param verificationStrategy The strategy used to verify the model
     * @param modelName The name of the model (unique)
     */
    function createNewModel(
        address modelVerifier,
        VerificationStrategy verificationStrategy,
        string memory modelName,
        uint256 computeCost,
        uint256 requiredFUCUs
    ) external returns (uint256 modelId);

    /**
     * @notice The function to update the name of a model
     * @param modelId The id of the model
     * @param modelName The new name of the model (unique)
     */
    function updateModelName(uint256 modelId, string memory modelName) external;

    /**
     * @notice The function to update the compute cost of a model
     * @param modelId The id of the model
     * @param computeCost The new compute cost of the model
     */
    function updateComputeCost(uint256 modelId, uint256 computeCost) external;

    /**
     * @notice The function to update the required FUCUs of a model
     * @param modelId The id of the model
     * @param requiredFUCUs The new required FUCUs of the model
     */
    function updateRequiredFUCUs(uint256 modelId, uint256 requiredFUCUs) external;

    /**
     * @notice The function to update the model verifier of a model
     * @param modelId The id of the model
     * @param modelVerifier The new address of the model verifier
     */
    function updateModelVerifier(uint256 modelId, address modelVerifier) external;

    /**
     * @notice The function to update the verification strategy of a model
     * @param modelId The id of the model
     * @param verificationStrategy The new verification strategy of the model
     */
    function updateVerificationStrategy(
        uint256 modelId,
        VerificationStrategy verificationStrategy
    ) external;

    /**
     * @notice Disable a model by clearing its verifier. Disabled models cannot be used by the TaskManager.
     * @param modelId The id of the model to disable
     */
    function disableModel(uint256 modelId) external;

    /**
     * @notice Get the number of active models
     */
    function activeModelsLength() external view returns (uint256);

    /**
     * @notice Get the full list of active models (use with care for large sets)
     */
    function getActiveModels() external view returns (uint256[] memory ids);

    /**
     * @notice Return a pseudo-random active model id using provided seed
     */
    function getRandomActiveModel(uint256 seed) external view returns (uint256);

    /**
     * @notice Check whether a model is active
     */
    function isActive(uint256 modelId) external view returns (bool);
}
