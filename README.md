# Agri-Harvest

<p align="center">
  <img src="https://img.shields.io/badge/python-3.12+-blue" />
  <img src="https://img.shields.io/badge/license-MIT-green" />
  <img src="https://img.shields.io/badge/tests-207-brightgreen" />
  <img src="https://img.shields.io/badge/dataset-3M%20rows-orange" />
</p>

End-to-end yield prediction platform for Cameroon agriculture. Ingests soil, climate, satellite, and crop survey data through two ML pipelines (scikit-learn and LightGBM/XGBoost/PyTorch) to predict harvest yields across 8 agroecological zones and 27 crop types.

## Table of contents

- [Quick start](#quick-start)
- [Dataset](#dataset)
- [Project structure](#project-structure)
- [Models](#models)
- [Benchmarks](#benchmarks)
- [Features](#features)
- [Data validation](#data-validation)
- [Agroecological zones](#agroecological-zones)
- [Climate data collection](#climate-data-collection)
- [Configuration](#configuration)
- [API](#api)
- [Testing](#testing)
- [License](#license)

## Quick start

```bash
git clone https://github.com/farmstomarket/agri-harvest-cameroon.git
cd agri-harvest-cameroon
python -m venv .venv && source .venv/bin/activate

pip install -e ".[ml,dev]"
cp .env.example .env
```

Train a model in three lines:

```python
from models.v1.trainer import YieldModelTrainer

trainer = YieldModelTrainer("data/features.parquet")
comparison = trainer.run(["lightgbm"], optimize=True)
```

Requires Python 3.12+.

## Dataset

The training dataset (3M rows) is hosted on Hugging Face:

**[synthi-ai/cameroon-agricultural-data](https://huggingface.co/datasets/synthi-ai/cameroon-agricultural-data)**

| Property | Value |
|---|---|
| Rows | 3,000,000 |
| Columns | 36 raw / 66 engineered |
| Crops | 27 types across 7 groups (cereals, legumes, root & tubers, vegetables, tree crops, industrial, cash crops) |
| Zones | 8 agroecological zones |
| Period | 2018 -- 2024 |
| Sources | Field measurements, weather stations, lab analyses, TerraClimate, CHIRPS |

```python
from datasets import load_dataset

ds = load_dataset("synthi-ai/cameroon-agricultural-data", split="train")
df = ds.to_pandas()
```

Three Jupyter notebooks walk through the data pipeline:

| Notebook | Purpose |
|---|---|
| `01_data_exploration.ipynb` | Exploratory data analysis |
| `02_feature_engineering.ipynb` | Feature engineering (36 raw -> 66 features) |
| `data_generation_notebook.ipynb` | Synthetic data generation |

## Project structure

```
agri-harvest/
├── config/
│   ├── schema/             # Pydantic v2 validation (crop, soil, weather)
│   ├── yaml/               # Geography, agriculture, model hyperparameters
│   ├── json/               # External data schemas (IRAD, satellite, NetCDF)
│   ├── settings.py         # Runtime settings via pydantic-settings
│   └── yaml_loader.py      # YAML config loader
├── data/
│   ├── collectors/         # TerraClimate (OpenDAP) + CHIRPS clients
│   └── processing/         # Aggregation and export utilities
├── models/
│   ├── config.py           # Feature lists, leakage guard, ModelConfig
│   ├── data_loader.py      # CSV loading, prepare_features, spatial split
│   ├── preprocessing.py    # ColumnTransformer (StandardScaler + passthrough)
│   ├── estimators.py       # Ridge, RF, HGB, Stacking registry
│   ├── evaluator.py        # RMSE, MAE, R2, MAPE metrics
│   ├── trainer.py          # v0 orchestrator
│   ├── predict.py          # v0 inference with feature validation
│   ├── persistence.py      # joblib + JSON metadata persistence
│   ├── feature_analysis.py # Feature importances (tree-based + permutation)
│   └── v1/
│       ├── config.py           # v1 config (LGB, XGB, YieldNet, time-series)
│       ├── data_loader.py      # Polars-based loading, dtype optimization
│       ├── preprocessing.py    # Missing value imputation, PyTorch scaling
│       ├── estimators.py       # YieldNet, LightGBM/XGBoost param builders
│       ├── evaluator.py        # Same metrics API as v0
│       ├── trainer.py          # v1 orchestrator (LGB, XGB, YieldNet)
│       ├── predict.py          # v1 inference (LGB/XGB/PyTorch auto-detect)
│       ├── persistence.py      # Format-specific save/load (txt, json, pt)
│       ├── tuning.py           # Optuna hyperparameter optimization
│       ├── time_series.py      # HybridYieldModel (LSTM) + TransformerYieldModel
│       ├── feature_analysis.py # LightGBM SHAP + gain importances
│       └── convert_parquet.py  # CSV -> Parquet conversion utility
├── utils/                  # Geospatial, date, file utilities
├── scripts/
│   └── collect_climate.py  # CLI for TerraClimate / CHIRPS collection
├── notebooks/              # EDA, feature engineering, data generation
├── tests/unit/             # 207 unit tests
├── docs/source/            # Sphinx documentation
├── main.py                 # FastAPI entry point
├── pyproject.toml
├── setup.py
└── Makefile
```

## Models

### v0 -- scikit-learn (up to ~500K rows)

Spatial train/test split on `agroecological_zone` via `GroupShuffleSplit` (no zone leaks across sets). `StandardScaler` on 40 continuous features, passthrough for 22 binary + 4 ordinal.

| Model | Type | Hyperparameters |
|---|---|---|
| Stacking | Ensemble | RF + HGB base, Ridge meta-learner |
| Hist Gradient Boosting | Boosting | 500 iters, depth 8, lr 0.05 |
| Random Forest | Bagging | 300 trees, depth 20, min_leaf 10 |
| Ridge | Linear | alpha 1.0 |
| Baseline | Dummy | Mean strategy (sanity check) |

```python
from models.trainer import YieldModelTrainer

trainer = YieldModelTrainer("data/features.csv")
comparison = trainer.run()                    # all 5 models
comparison = trainer.run(["random_forest"])    # single model
```

### v1 -- LightGBM / XGBoost / PyTorch (10M+ rows)

Polars-based loading with dtype optimization (Float64 -> Float32, string -> Categorical). Stratified split on `agroecological_zone`. Missing value imputation fitted on train, applied to test.

| Model | Type | Hyperparameters |
|---|---|---|
| LightGBM | GBDT (native API) | 128 leaves, lr 0.05, 2000 rounds, early stop 50 |
| XGBoost | GBDT (hist) | depth 12, lr 0.05, 800 estimators |
| YieldNet | PyTorch MLP | [512, 256, 128], dropout 0.3, AdamW, cosine LR |
| HybridYieldModel | LSTM + MLP | 2-layer LSTM (hidden 128) + configurable tabular branch |
| TransformerYieldModel | Transformer + MLP | 4-layer encoder, 8 heads, GELU, sinusoidal PE |

LightGBM receives raw data (handles NaN natively). XGBoost and YieldNet receive imputed data.

**Time-series models** consume per-field daily weather sequences (temperature min/max, precipitation, humidity, solar radiation) up to 180 days alongside static features. Variable-length sequences are handled via masked mean pooling. The tabular branch dimensions are configurable via `tabular_hidden` and `tabular_dropout` in `models_v1.yaml`.

**Hyperparameter tuning**: Optuna with model-specific pruning callbacks (`LightGBMPruningCallback`, `XGBoostPruningCallback`, median pruner for YieldNet). Search spaces defined in `config/yaml/models_v1.yaml`.

```python
from models.v1.trainer import YieldModelTrainer

trainer = YieldModelTrainer("data/features.parquet")
comparison = trainer.run()                                # all 3 models
comparison = trainer.run(["lightgbm"], optimize=True)     # with Optuna
```

### Inference

Both pipelines validate inputs at prediction time: missing features raise `ValueError` with the list of absent columns, and columns are reordered to match training order. For PyTorch models, `input_dim` is also verified.

```python
from models.predict import YieldPredictor          # v0
from models.v1.predict import YieldPredictor       # v1 (auto-detects .txt/.json/.pt)

predictor = YieldPredictor("data/models/best_model.joblib")
yield_kg = predictor.predict_single({"latitude": 3.87, "longitude": 11.52, ...})
```

### Leakage guard

Both pipelines exclude target-derived features before training:

```
nue, wue, yield_gap_ratio, harvest_index, biomass_kg_ha
```

This is enforced at the config level and verified by dedicated unit tests that assert these columns are absent from `X` after `prepare_features()`.

## Benchmarks

Results on 3M rows from [`synthi-ai/cameroon-agricultural-data`](https://huggingface.co/datasets/synthi-ai/cameroon-agricultural-data). Metrics on held-out test sets.

### v0 (80/20 spatial split, ~600K test rows, target: `yield_kg_ha`)

| Model | RMSE (kg/ha) | MAE (kg/ha) | R2 | MAPE |
|---|---:|---:|---:|---:|
| Stacking (RF+HGB) | 412.7 | 287.3 | 0.9218 | 11.4% |
| Hist Gradient Boosting | 431.5 | 301.8 | 0.9145 | 12.1% |
| Random Forest | 458.2 | 322.6 | 0.9036 | 13.0% |
| Ridge | 689.4 | 512.7 | 0.7821 | 19.8% |
| Baseline (mean) | 1,534.6 | 1,247.1 | 0.0000 | 46.8% |

### v1 (85/15 stratified split, ~450K test rows, target: `yield_tha`)

| Model | RMSE (t/ha) | MAE (t/ha) | R2 | MAPE |
|---|---:|---:|---:|---:|
| LightGBM | 0.3514 | 0.2418 | 0.9435 | 9.6% |
| XGBoost | 0.3687 | 0.2541 | 0.9378 | 10.2% |
| YieldNet (PyTorch) | 0.4023 | 0.2856 | 0.9259 | 11.3% |

<details>
<summary>LightGBM breakdown by zone</summary>

| Agroecological zone | RMSE (t/ha) | R2 | N |
|---|---:|---:|---:|
| Humid forest (inland) | 0.3124 | 0.9542 | 128,430 |
| Humid forest (coast) | 0.3287 | 0.9489 | 68,715 |
| Western highlands | 0.3401 | 0.9451 | 54,180 |
| Guinea savanna | 0.3598 | 0.9387 | 85,245 |
| Forest-savanna transition | 0.3712 | 0.9334 | 49,590 |
| Sudan savanna | 0.3945 | 0.9258 | 40,320 |
| Sahel savanna | 0.4378 | 0.9124 | 23,520 |

</details>

<details>
<summary>LightGBM breakdown by crop group</summary>

| Crop group | RMSE (t/ha) | R2 | N |
|---|---:|---:|---:|
| Cereals | 0.3245 | 0.9512 | 144,870 |
| Root & tubers | 0.3412 | 0.9467 | 94,725 |
| Legumes | 0.3567 | 0.9398 | 70,515 |
| Tree crops | 0.3734 | 0.9321 | 55,530 |
| Vegetables | 0.3856 | 0.9278 | 84,360 |

</details>

> These results are indicative and will vary with dataset version. Run `trainer.run()` to reproduce.

## Features

66 engineered features across 6 categories (from 36 raw columns):

| Category | Count | Examples |
|---|---:|---|
| Location | 14 | latitude, longitude, elevation, zone one-hots, altitude class one-hots |
| Climate | 13 | temp min/max/mean, precipitation, humidity, solar radiation, GDD, VPD, aridity index |
| Soil | 9 | pH, organic carbon, nitrogen, phosphorus, sand/clay %, fertility index, C:N ratio, CEC |
| Management | 8 | fertilizer N/P, organic fertilizer, irrigation, input intensity, total mineral fert |
| Temporal | 10 | month sin/cos, day-of-year sin/cos, year, season ordinal, rainy season flag |
| Interactions | 6 | humidity-temp, rain-OC, input-soil, water supply index, disease risk score |

Evaluation uses RMSE, MAE, R2, and MAPE with epsilon = 1.0 kg/ha to guard against division by near-zero actuals.

## Data validation

Pydantic v2 schemas (`config/schema/`) enforce Cameroon-specific domain constraints at data ingestion:

| Domain | Constraints |
|---|---|
| Coordinates | lat 1.6--13.1 N, lon 8.3--16.2 E, elevation 0--4,095 m |
| Soil | Texture sums to 100% (1% tolerance), pH 3.5--9.5, bulk density 0.8--2.0 g/cm3 |
| Weather | Temperature -5 to 50 C, precipitation 0--500 mm/day, pressure 600--1,050 hPa |
| Crops | 27 types, 7 groups, harvest index ranges per crop, yield <= biomass |

Auto-derived fields: `day_of_year`, `season`, `rainfall_regime`, `temperature_avg`, `diurnal_range`, `soil_porosity`, `available_water_capacity`.

## Agroecological zones

Classification based on latitude, longitude, and elevation:

| Zone | Criteria | Typical crops |
|---|---|---|
| Sahel savanna | lat > 10 N | sorghum, millet, cotton |
| Sudan savanna | 8--10 N | sorghum, groundnut |
| Guinea savanna | 6--8 N | maize, yam |
| Western highlands | elev > 1,200 m, lon < 11.5 E, lat 4.5--7.5 N | potato, maize |
| Forest-savanna transition | 5--6 N | maize, cassava |
| Humid forest (coast) | lat < 5, lon < 10, elev < 500 m | cocoa, plantain |
| Humid forest (inland) | lat < 5, interior | cocoa, cassava |
| Mont Cameroun volcanic | lat 4.0--4.35, lon 9.0--9.35, elev > 2,500 m | specialty crops |

Season classification: **bimodal** (south, lat < 6 N) with 5 seasons, **monomodal** (north, lat >= 6 N) with 4 seasons.

## Climate data collection

Real climate observations from TerraClimate (monthly, OpenDAP/THREDDS) and CHIRPS (daily precipitation):

```bash
python scripts/collect_climate.py --source terraclimate --lat 3.87 --lon 11.52 --year 2023
python scripts/collect_climate.py --source chirps --lat 3.87 --lon 11.52 --year 2023
```

The `data/collectors/` module provides the underlying clients with coordinate validation and variable mapping.

## Configuration

All hyperparameters and domain constants are externalized to YAML:

| File | Contents |
|---|---|
| `geography.yaml` | Cameroon bounds, 8 zone thresholds, season definitions |
| `agriculture.yaml` | 13 main crops, soil texture classes, 5 IRAD research centers |
| `climate_sources.yaml` | TerraClimate and CHIRPS source configuration |
| `models_v0.yaml` | Feature lists (40 + 22 + 4), estimator hyperparameters, n_jobs, 80/20 split |
| `models_v1.yaml` | LGB/XGB/YieldNet params, Optuna search spaces, time-series config, 85/15 split |

Runtime settings (host, port, log level, secret key) via `.env` and `pydantic-settings`. See `.env.example`.

## API

FastAPI application with health check endpoint:

```bash
python main.py                    # starts on http://0.0.0.0:8000
curl http://localhost:8000/health  # {"status": "ok"}
```

## Testing

```bash
pytest tests/ -v          # 207 tests
make test                 # shortcut
```

Test coverage includes:
- **Schemas**: coordinate bounds, soil texture sums, weather ranges, crop constraints
- **Geospatial**: zone classification, distance calculations, UTM conversion
- **Date utilities**: season detection, GDD calculation, date range validation
- **Models v0**: estimator fit/predict, evaluator metrics, persistence roundtrip, leakage guard, predictor validation
- **Models v1**: data loading, preprocessing, LightGBM/XGBoost/YieldNet, Optuna tuning, time-series models, MAPE near-zero stability

## Installation

### Minimal (API + data validation only)

```bash
pip install -e "."
```

### ML pipelines

```bash
pip install -e ".[ml]"
```

### Climate data collection

```bash
pip install -e ".[climate]"
```

### Geospatial utilities

```bash
pip install -e ".[geo]"
```

### Development (tests, linting, type checking)

```bash
pip install -e ".[dev]"
```

### Everything

```bash
pip install -e ".[ml,geo,climate,dev]"
```

## License

MIT License -- Copyright (c) 2025 [SYNTHI-AI](https://synthi-ai.com)

## Contact

**SYNTHI-AI** -- contact@synthi-ai.com | contact@farmstomarket.io

For bug reports or feature requests, [open an issue](https://github.com/farmstomarket/agri-harvest-cameroon/issues).
