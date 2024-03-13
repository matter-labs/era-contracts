build: preprocess
	@echo "Building contracts..."
	@forge build
	@echo "Build finished."

preprocess:
	@echo "Preprocessing contracts..."
	@python3 ../scripts/preprocess-sol.py ../l1-contracts/contracts --config ../SystemConfig.json --output ./out/src
	@echo "Preprocessing finished."
