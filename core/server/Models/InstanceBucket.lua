InstanceBucket = BaseModel:extend('instance_buckets')

InstanceBucket.primaryKey = 'id'
InstanceBucket.timestamps = true
InstanceBucket.fillable = { 'key', 'bucket_id' }

return InstanceBucket
